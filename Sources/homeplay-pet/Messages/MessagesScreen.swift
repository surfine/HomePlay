// 桌寵螢幕上的「訊息」畫面（對話列表、對話頁、新訊息），照設計稿 Messages.dc.html 起頭，2.0 imsg 補齊手錶／iOS 27 的樣子：
// 列表＝頭像（聯絡人照片，沒有就 Apple 灰色縮寫圓；群組兩個疊在一起）、未讀藍點、時間與 ›、釘選的大頭像；
// 對話頁＝最新的貼在底部、帶尾巴的泡泡（iMessage 藍／SMS 綠／收到的淺灰）、時間分隔、群組寄件人與頭像、
// 回覆串引用、Tapback 角標（右上／左上，iOS 18 起的彩色）、已編輯、已收回、已送達／已讀、特效的「↺ 重播」、
// 大表情（不帶泡泡）、照片／影片／貼圖／語音訊息／連結預覽／檔案（官方影片 v1 01:37.5「C u at 7:20???」那一幕）。
// 畫在給定的 CGContext 與矩形上（畫布左上原點，同 Face 的 makeImage）；純繪製、不持有狀態，所以也能在殼層之外單獨渲染。
// 版面與點擊測試共用同一次 layout：draw 回傳的 [(MessagesHit, CGRect)] 就是命中表。觸控目標 ≥ 88。
// 材質：內容層（泡泡、列表、照片）不上玻璃；控制層（按鈕、建議回覆）在殼層裡用系統液態玻璃（controlGlass），
// 沒有殼層時（單獨渲染、過場縮放中）退回半透明填色，命中矩形不變。
// 隱私：不記錄任何文字。

import AppKit
import CoreText

// MARK: - 畫面模型

struct MessagesListModel {
    struct Pin { var id: String; var name: String; var initial: String; var unread: Bool; var avatar: CGImage? = nil }
    struct Row {
        var id: String; var name: String; var last: String; var time: String; var unread: Bool
        var avatar: CGImage? = nil
        var initials: [String] = []    // 一個＝一對一；兩個＝群組（疊兩個圓）
    }
    var pins: [Pin]
    var rows: [Row]
    var access: MessagesAccess = .available
    /// 捲動：從第幾列開始畫（殼層的 App 用）
    var firstRow = 0
    /// 標題往右讓多少（殼層左上角有關閉鈕）；nil＝照設計稿
    var titleLeading: CGFloat?
    /// 第一次讀 chat.db 還沒回來（不要先閃「沒有對話」）
    var loading = false
}

struct MessagesThreadModel {
    var title: String
    var items: [MessagesItem]      // 舊到新
    var chips: [String]            // 建議回覆，最多 3 個
    /// 捲動：最新的幾個項目先不畫（往上看舊訊息）
    var skipNewest = 0
    /// 2.0: 畫在外殼裡（左上返回鈕對齊外殼膠囊的位置、右上留給時間）
    var inShell = false
    var isGroup = false
    /// 縮圖：(參照, 是不是影片) → 圖；nil＝還沒好（畫佔位）
    var image: (MessagesMediaRef, Bool) -> CGImage? = { _, _ in nil }
    var audioSeconds: (MessagesMediaRef) -> Double? = { _ in nil }
    var playing: (id: Int64, progress: Double)?
    /// 隱形墨水已經點開的訊息
    var revealed: Set<Int64> = []
    /// 「重播」：哪一則、0…1
    var pulse: (row: Int64, t: CGFloat)?
    /// 底部要不要畫建議回覆（新訊息頁沒有）
    var showsChips = true
    /// 還在讀這串對話
    var loading = false
    /// 附件不在這台 Mac 上（iCloud 的「最佳化儲存空間」清掉了，或還沒下載）
    var missing: (MessagesMediaRef) -> Bool = { _ in false }
}

/// 新訊息：先選收件人（最近的對話＋通訊錄），選好之後跟對話頁一樣用說的／打字／表情
struct MessagesComposeModel {
    struct Suggestion { var id: String; var name: String; var detail: String; var initials: String; var avatar: CGImage? = nil }
    var recipient: String?         // 已選的名字；nil＝還在選
    var query: String              // 打字或說出的名字
    var suggestions: [Suggestion]
}

enum MessagesScreenModel {
    case list(MessagesListModel)
    case thread(MessagesThreadModel)
    case compose(MessagesComposeModel)
}

enum MessagesHit: Equatable {
    case none, newMessage, back, speak, type, emoji, openSettings
    case pin(String), row(String), chip(Int), item(Int)
    case suggestion(Int), sayName, typeName, clearRecipient
}

// MARK: - 釘選（HomePlay 自己記，無法與 iPhone 同步）

enum MessagesPins {
    static let key = "HomePlayMessagesPins"
    static func load(_ d: UserDefaults = .standard) -> [String] { d.stringArray(forKey: key) ?? [] }
    static func toggle(_ guid: String, _ d: UserDefaults = .standard) {
        var l = load(d)
        if let i = l.firstIndex(of: guid) { l.remove(at: i) } else { l.append(guid) }
        d.set(l, forKey: key)
    }
}

extension MessagesListModel {
    /// 真資料 → 畫面：釘選的對話上排大頭像（不重複出現在列表），其餘依時間。
    /// avatar：handle → 聯絡人照片（沒授權或沒照片＝nil，畫縮寫）；seen：本機看過的游標（MessagesSeen）
    static func from(_ convs: [MsgConversation], pins: [String], access: MessagesAccess = .available, now: Date = Date(),
                     seen: [String: Int64] = [:], avatar: (String) -> CGImage? = { _ in nil }, name: (String) -> String? = { _ in nil }) -> MessagesListModel {
        let pinned = pins.compactMap { g in convs.first { $0.guid == g } }
        let rest = convs.filter { c in !pins.contains(c.guid) }
        func sum(_ c: MsgConversation) -> String {
            c.lastText.isEmpty ? (c.lastHasAttachments ? L("msg.attachment", "附件") : "") : c.lastText
        }
        func initials(_ c: MsgConversation) -> [String] {
            guard c.isGroup else { return [MessagesThreadBuilder.initials(c.title)] }
            return c.participants.prefix(2).map { MessagesThreadBuilder.initials(name($0) ?? $0) }
        }
        func photo(_ c: MsgConversation) -> CGImage? { c.isGroup ? nil : (c.participants.first ?? c.chatIdentifier).isEmpty ? nil : avatar(c.participants.first ?? c.chatIdentifier) }
        return MessagesListModel(
            pins: pinned.map { c in
                .init(id: c.guid, name: c.title, initial: initials(c).first ?? "?", unread: MessagesSeen.isUnread(c, seen: seen), avatar: photo(c))
            },
            rows: rest.map { c in
                .init(id: c.guid, name: c.title, last: sum(c), time: MessagesScreen.timeLabel(c.lastDate, now: now),
                      unread: MessagesSeen.isUnread(c, seen: seen), avatar: photo(c), initials: initials(c))
            },
            access: access)
    }
}

// MARK: - 繪製

enum MessagesScreen {
    typealias Hits = [(MessagesHit, CGRect)]

    /// 設計稿 378 → 畫布 1024
    static let k: CGFloat = 1024.0 / 378.0
    // 2.0 r2（R2）：跟著 Theme 的淺／深色（影片 v1 01:37.5：白天的訊息是淺色，收到的泡泡淺灰黑字、送出的 iMessage 藍白字）
    private static var blue: NSColor { HPTokens.blue }
    private static var green: NSColor { HPTokens.green }
    private static var incoming: NSColor { HPTokens.dark ? srgb(0x26262a) : srgb(0xe9e9eb) }
    private static var badgeBG: NSColor { HPTokens.dark ? srgb(0x3a3a3e) : srgb(0xe5e5ea) }
    private static var controlFill: NSColor { HPTokens.dark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.06) }
    private static var label: NSColor { HPTokens.label }
    private static var secondary: NSColor { HPTokens.secondary }
    private static var background: NSColor { HPTokens.dark ? .black : .white }
    /// 殼層給的玻璃（R13：GlassPass）：(畫布, 1024 座標的形狀, 快取鍵, 玻璃上面的內容) → 畫了沒；nil 或回 false 就用 controlFill 再畫內容
    nonisolated(unsafe) static var controlGlass: ((CGContext, CGPath, String, @escaping (CGContext) -> Void) -> Bool)?

    /// 時間標籤：今天的時間（時制照系統）、昨天、一週內的星期、其餘 M/d
    static func timeLabel(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let f = DateFormatter(); f.locale = L10n.language.locale; f.calendar = calendar
        if calendar.isDate(d, inSameDayAs: now) { Face.setTimeFormat(f); return f.string(from: d) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: d), to: calendar.startOfDay(for: now)).day ?? 99
        if days == 1 { return L("msg.yesterday", "昨天") }
        if days > 1 && days < 7 { f.dateFormat = "EEE"; return f.string(from: d) }
        f.setLocalizedDateFormatFromTemplate("Md"); return f.string(from: d)
    }

    /// 畫進 rect（ctx 為左上原點的畫布；rect 等比對應 1024 單位），回傳命中表（已換算到 ctx 座標）
    @discardableResult
    static func render(_ model: MessagesScreenModel, in g: CGContext, rect: CGRect) -> Hits {
        g.saveGState(); defer { g.restoreGState() }
        let s = rect.width / 1024
        g.translateBy(x: rect.minX, y: rect.minY); g.scaleBy(x: s, y: s)
        var hits = Hits()
        g.setFillColor(background.cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        switch model {
        case .list(let m): drawList(g, m, &hits)
        case .thread(let m): drawThread(g, m, &hits)
        case .compose(let m): drawCompose(g, m, &hits)
        }
        return hits.map { ($0.0, CGRect(x: rect.minX + $0.1.minX * s, y: rect.minY + $0.1.minY * s, width: $0.1.width * s, height: $0.1.height * s)) }
    }

    /// 點在 p（ctx／視窗座標，與 render 的 rect 同一個系）時點到哪個元素；後畫的蓋在上面
    static func hit(_ model: MessagesScreenModel, in rect: CGRect, at p: CGPoint) -> MessagesHit {
        let hits = layout(model, in: rect)
        return hits.last { $0.1.contains(p) }?.0 ?? .none
    }

    /// 只算版面不畫（畫在 1×1 的丟棄畫布上）
    static func layout(_ model: MessagesScreenModel, in rect: CGRect) -> Hits {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let g = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        let glass = controlGlass; controlGlass = nil; defer { controlGlass = glass }   // 只算版面：不要真的算玻璃
        return render(model, in: g, rect: rect)
    }

    // MARK: 對話列表

    private static func drawList(_ g: CGContext, _ m: MessagesListModel, _ hits: inout Hits) {
        let pad = HPTokens.Space.margin, W: CGFloat = 1024
        var y: CGFloat
        if let lead = m.titleLeading {
            let tl = HPComponents.titleLayout(L("msg.title", "信息"))   // 不壓 👀 膠囊
            text(g, L("msg.title", "信息"), tl.font, label, x: lead, y: tl.baseline)
            y = HPTokens.contentTop - 6
        } else {
            let btn = 38 * k
            let titleFont = FaceType.sf(22 * k, .bold, mono: false)
            text(g, L("msg.title", "信息"), titleFont, label, x: pad, y: 26 * k + btn / 2 + titleFont.capHeight / 2)
            y = 26 * k + btn + 12 * k
        }
        // 沒權限／沒資料庫：解釋卡
        if m.access != .available { drawAccessCard(g, m.access, top: y, &hits); return }
        // 手錶的列表最上面是「新訊息」膠囊鈕
        let compose = CGRect(x: pad, y: y, width: W - 2 * pad, height: 96)
        let bf = HPType.sf(HPType.Size.button, .semibold), ink = label
        controlPill(g, compose) { g in
            let s = L("msg.new", "新信息")
            let w = width(s, bf) + 56
            symbol(g, "square.and.pencil", in: CGRect(x: compose.midX - w / 2, y: compose.midY - 22, width: 40, height: 40), color: ink)
            text(g, s, bf, ink, x: compose.midX - w / 2 + 56, y: compose.midY + bf.capHeight / 2)
        }
        hits.append((.newMessage, compose))
        HPAX.note(g, compose, .button, L("msg.new", "新信息"))
        y = compose.maxY + 30
        // 釘選：大頭像（最多 4 個），名字在下面
        if !m.pins.isEmpty {
            let d: CGFloat = 150, slot = (W - 2 * pad) / 4
            let lf = HPType.sf(30, .regular)
            for (i, p) in m.pins.prefix(4).enumerated() {
                let cx = pad + slot * (CGFloat(i) + 0.5)
                let c = CGRect(x: cx - d / 2, y: y, width: d, height: d)
                avatar(g, c, image: p.avatar, initials: [p.initial])
                if p.unread {
                    let r = CGRect(x: c.minX - 2, y: c.minY + 6, width: 34, height: 34)
                    circle(g, r.insetBy(dx: -5, dy: -5), background); circle(g, r, blue)
                }
                text(g, p.name, lf, secondary, x: cx, y: c.maxY + 40, maxWidth: slot - 12, align: .center)
                hits.append((.pin(p.id), CGRect(x: cx - slot / 2, y: y, width: slot, height: d + 56)))
                HPAX.note(g, CGRect(x: cx - slot / 2, y: y, width: slot, height: d + 56), .button, p.name, value: p.unread ? L("msg.ax.unread", "未读") : nil, shape: .circle)
            }
            y += d + 56 + 24
        }
        if m.rows.isEmpty {
            let f = HPType.sf(HPType.Size.list, .semibold)
            if m.loading && m.pins.isEmpty { loadingState(g, y: y + 120) ; return }
            text(g, m.pins.isEmpty ? L("msg.empty", "没有对话") : "", f, secondary, x: W / 2, y: y + 160, align: .center)
            return
        }
        // 對話列：未讀點、頭像、名字＋時間 ›、預覽兩行
        let rowH: CGFloat = 168, av: CGFloat = 112, dot: CGFloat = 22
        let nf = HPType.sf(HPType.Size.list, .semibold), lf = HPType.sf(HPType.Size.secondary, .regular), tf = HPType.sf(HPType.Size.secondary, .regular)
        for (ri, r) in m.rows.dropFirst(max(0, m.firstRow)).enumerated() where y + rowH <= 1024 - 30 {
            let avX = pad + dot + 14
            let textX = avX + av + 28
            if ri > 0 { g.setFillColor(HPTokens.separator.cgColor); g.fill(CGRect(x: textX, y: y, width: W - pad - textX, height: 2)) }
            let avR = CGRect(x: avX, y: y + (rowH - av) / 2, width: av, height: av)
            if r.unread { circle(g, CGRect(x: pad, y: avR.midY - dot / 2, width: dot, height: dot), blue) }
            avatar(g, avR, image: r.avatar, initials: r.initials)
            let tw = width(r.time, tf)
            let nameBase = y + 66
            text(g, r.name, nf, label, x: textX, y: nameBase, maxWidth: W - pad - tw - 60 - textX)
            text(g, r.time, tf, secondary, x: W - pad - 34, y: nameBase, align: .right)
            symbol(g, "chevron.right", in: CGRect(x: W - pad - 22, y: nameBase - 26, width: 20, height: 28), color: HPTokens.tertiary)
            let lines = wrap(r.last, lf, W - pad - textX, maxLines: 2)
            for (li, l) in lines.enumerated() {
                text(g, l, lf, secondary, x: textX, y: nameBase + 44 + CGFloat(li) * 40, maxWidth: W - pad - textX)
            }
            hits.append((.row(r.id), CGRect(x: 0, y: y, width: W, height: rowH)))
            HPAX.note(g, CGRect(x: pad, y: y, width: W - 2 * pad, height: rowH), .button, r.name,
                      value: [r.unread ? L("msg.ax.unread", "未读") : nil, r.last, r.time].compactMap { $0 }.joined(separator: ", "), shape: .rounded(24))
            y += rowH
        }
    }

    private static func drawAccessCard(_ g: CGContext, _ a: MessagesAccess, top: CGFloat, _ hits: inout Hits) {
        let tf = FaceType.sf(17 * k, .bold, mono: false), bf = FaceType.sf(13 * k, .regular, mono: false)
        let title = a == .needsFullDiskAccess ? L("msg.fda.title", "需要「完全磁盘访问」") : L("msg.nodb.title", "找不到信息数据库")
        let body = a == .needsFullDiskAccess
            ? L("msg.fda.body", "要读「信息」里的对话，请在系统设置里打开 HomePlay。内容只在这台 Mac 上读取，不会上传。")
            : L("msg.nodb.body", "这台 Mac 还没有登入「信息」。登入后这里就会出现对话。")
        var yy = max(top, 250)
        for l in wrap(title, tf, 1024 - 2 * 70, maxLines: 2) { text(g, l, tf, label, x: 512, y: yy + tf.capHeight, align: .center); yy += 54 }
        yy += 14
        for l in wrap(body, bf, 1024 - 2 * 90, maxLines: 4) { text(g, l, bf, secondary, x: 512, y: yy + bf.capHeight, align: .center); yy += 48 }
        if a == .needsFullDiskAccess {
            let b = CGRect(x: 512 - 260, y: min(yy + 20, 1024 - 36 - 120 - 40), width: 520, height: 120)
            pill(g, b, fill: blue)
            let f = FaceType.sf(15 * k, .semibold, mono: false)
            text(g, L("msg.fda.open", "打开系统设置"), f, .white, x: b.midX, y: b.midY + f.capHeight / 2, maxWidth: b.width - 40, align: .center)
            hits.append((.openSettings, b))
        }
    }

    // MARK: 頂列、底部按鈕（對話頁與新訊息共用）

    private static func drawHeader(_ g: CGContext, title: String, inShell: Bool, _ hits: inout Hits) {
        let pad = 24 * k, bd = 34 * k, W: CGFloat = 1024
        // 2.0 r2：外殼裡返回鈕（‹）在 HPTokens.backButton，子頁大標題＝對話名稱（HPTokens.titleFont）；右上是時間
        let back: CGRect = inShell ? HPTokens.backButton : CGRect(x: pad, y: 22 * k, width: bd, height: bd)
        let ink = label
        controlCircle(g, back) { g in
            g.setStrokeColor(ink.cgColor); g.setLineWidth(3 * k * 14 / 24); g.setLineCap(.round); g.setLineJoin(.round)
            let cs = 14 * k / 24 * 24 / 2
            g.move(to: CGPoint(x: back.midX + cs * 0.2, y: back.midY - cs * 0.58)); g.addLine(to: CGPoint(x: back.midX - cs * 0.42, y: back.midY))
            g.addLine(to: CGPoint(x: back.midX + cs * 0.2, y: back.midY + cs * 0.58)); g.strokePath()
        }
        hits.append((.back, back))
        HPAX.note(g, back, .button, L("msg.ax.back", "返回"), shape: .circle)
        HPAX.note(g, CGRect(x: back.maxX + 20, y: back.minY, width: 560, height: back.height), .heading, title)
        if inShell {
            let tl = HPComponents.titleLines(title)   // 放不下就縮、換兩行、中間截斷，不壓 👀 膠囊
            for (line, y) in zip(tl.lines, tl.baselines) { text(g, line, tl.font, label, x: tl.x, y: y, maxWidth: tl.width) }
        } else {
            let tf = FaceType.sf(16 * k, .bold, mono: false)
            text(g, title, tf, label, x: back.maxX + 10 * k, y: back.midY + tf.capHeight / 2, maxWidth: W - pad - (back.maxX + 10 * k))
        }
    }

    /// 底部：🎤 說話、⌨ 打字（膠囊）、😊 表情（圓）；回傳按鈕列的上緣
    private static func drawInputBar(_ g: CGContext, speakTitle: String, _ hits: inout Hits, speak: MessagesHit = .speak, type: MessagesHit = .type, emoji: Bool = true) -> CGFloat {
        let pad = HPTokens.Space.margin, W: CGFloat = 1024
        let bh: CGFloat = 108, by = 1024 - 48 - bh, gap: CGFloat = 22
        let em = CGRect(x: W - pad - bh, y: by, width: bh, height: bh)
        let right = emoji ? em.minX - gap : W - pad
        let bw = (right - pad - gap) / 2
        let speakR = CGRect(x: pad, y: by, width: bw, height: bh), typeR = CGRect(x: pad + bw + gap, y: by, width: bw, height: bh)
        let bf = HPType.sf(HPType.Size.button, .semibold), ink = label
        for (r, s, sym) in [(speakR, speakTitle, "mic.fill"), (typeR, L("msg.type", "打字"), "keyboard")] {
            controlPill(g, r) { g in
                let w = width(s, bf) + 54
                let x0 = r.midX - min(w, r.width - 40) / 2
                symbol(g, sym, in: CGRect(x: x0, y: r.midY - 20, width: 40, height: 40), color: ink)
                text(g, s, bf, ink, x: x0 + 54, y: r.midY + bf.capHeight / 2, maxWidth: r.width - 54 - 40)
            }
        }
        hits.append((speak, speakR)); hits.append((type, typeR))
        HPAX.note(g, speakR, .button, speakTitle); HPAX.note(g, typeR, .button, L("msg.type", "打字"))
        if emoji {
            controlCircle(g, em) { g in symbol(g, "face.smiling", in: em.insetBy(dx: 30, dy: 30), color: ink) }
            hits.append((.emoji, em))
            HPAX.note(g, em, .button, L("msg.emoji", "表情"), shape: .circle)
        }
        return by
    }

    // MARK: 對話頁

    private static func drawThread(_ g: CGContext, _ m: MessagesThreadModel, _ hits: inout Hits) {
        let pad = HPTokens.Space.margin, W: CGFloat = 1024
        drawHeader(g, title: m.title, inShell: m.inShell, &hits)
        let by = drawInputBar(g, speakTitle: L("msg.speak", "用说的"), &hits)
        let ink = label

        // 建議回覆晶片：高度 ≥ 88，排不下就換行（最多兩排）
        let cf = HPType.sf(HPType.Size.button, .semibold)   // 2.0 depth：建議回覆是按鈕，用按鈕字級（原本 32）
        let chipH: CGFloat = 88, chipGap: CGFloat = 18
        var placed: [(Int, CGRect)] = [], cx = pad, row = 0
        for (i, c) in (m.showsChips ? Array(m.chips.prefix(3)) : []).enumerated() {
            let w = max(chipH, min(W - 2 * pad, width(c, cf) + 64))
            if cx + w > W - pad + 0.5, cx > pad { row += 1; cx = pad }
            if row > 1 { break }
            placed.append((i, CGRect(x: cx, y: CGFloat(row) * (chipH + chipGap), width: w, height: chipH)))
            cx += w + 18
        }
        let rows = placed.isEmpty ? 0 : row + 1
        let chipsH = rows == 0 ? 0 : CGFloat(rows) * chipH + CGFloat(rows - 1) * chipGap
        let chipsTop = by - 20 - chipsH
        for (i, r0) in placed {
            let r = r0.offsetBy(dx: 0, dy: chipsTop)
            let chip = m.chips[i]
            controlPill(g, r) { g in text(g, chip, cf, ink, x: r.midX, y: r.midY + cf.capHeight / 2, maxWidth: r.width - 28, align: .center) }
            hits.append((.chip(i), r))
            HPAX.note(g, r, .button, chip, value: L("msg.ax.suggestion", "建议回复"))
        }

        // 項目：由最新往上排到放不下為止（貼底，跟 iPhone／手錶一樣），再依時間順序畫
        let top: CGFloat = m.inShell ? HPTokens.contentTop : 200
        let bottom = (rows == 0 ? by : chipsTop) - 22
        if m.items.isEmpty {
            if m.loading { loadingState(g, y: top + 140) }
            else { text(g, L("msg.thread.empty", "还没有信息"), HPType.sf(HPType.Size.list, .semibold), secondary, x: W / 2, y: top + 180, align: .center) }
            return
        }
        var blocks: [(Int, Block)] = []
        var used: CGFloat = 0
        let all = Array(m.items.enumerated())
        var clipped = false
        for (i, it) in all.reversed().dropFirst(max(0, m.skipNewest)) {
            let b = measure(it, m)
            let prevGap: CGFloat = blocks.isEmpty ? 0 : gapBelow(it, next: m.items[blocks.last!.0])
            used += b.height + prevGap
            blocks.append((i, b))
            // 最上面那一個放不下：照樣畫、被上緣切掉（跟 iPhone 捲到一半一樣），再舊的就不畫
            if used > bottom - top { clipped = true; break }
        }
        var y = bottom - used
        g.saveGState()
        g.clip(to: CGRect(x: 0, y: top - 30, width: W, height: bottom - top + 30 + 200))
        let ordered = Array(blocks.reversed())
        for (n, (i, b)) in ordered.enumerated() {
            if n > 0 { y += gapBelow(m.items[ordered[n - 1].0], next: m.items[i]) }
            var local = Hits()
            draw(g, m.items[i], b, top: y, m, index: i, &local)
            hits += local.compactMap { h in   // 被切掉的部分點不到
                let r = h.1.intersection(CGRect(x: 0, y: top - 30, width: W, height: 2000))
                return r.height >= 88 ? (h.0, r) : nil
            }
            y += b.height
        }
        g.restoreGState()
        // 上面還有更舊的：淡出邊（內容層，不是玻璃）
        if clipped || blocks.count < m.items.count - max(0, m.skipNewest) {
            let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [background.cgColor, background.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
            g.saveGState(); g.clip(to: CGRect(x: 0, y: top - 30, width: W, height: 90))
            g.drawLinearGradient(grad, start: CGPoint(x: 0, y: top - 30), end: CGPoint(x: 0, y: top + 60), options: [])
            g.restoreGState()
        }
    }

    // 一個項目的版面
    private struct Block {
        var height: CGFloat
        var main: CGSize          // 泡泡／照片的大小
        var above: CGFloat        // 主體上面：寄件人、回覆引用、Tapback 角標的空間
        var below: CGFloat        // 主體下面：已編輯、狀態、重播
        var lines: [String] = []
    }

    // 2.0 depth：量官方 v1 01:37.5（f_0394）：「C u at 7:20???」等三個泡泡的字寬換回字級都是 41–42（螢幕寬 1060 px → 1024），
    // 跟我們的 list 字級一樣；泡泡下的「Today 7:12 AM」「Delivered」「Replay」量到 31–33，比原本的 28 大，改用 secondary
    // 跟著「螢幕文字大小」（HPType.textScale）走，所以是 var
    private static var bubbleFont: NSFont { HPType.sf(HPType.Size.list, .regular) }
    private static let hPad: CGFloat = 32, vPad: CGFloat = 20
    private static var lineH: CGFloat { HPType.Size.list * 1.28 }
    private static let maxBubble: CGFloat = 640
    private static var smallFont: NSFont { HPType.sf(HPType.Size.secondary, .medium) }
    private static let groupIndent: CGFloat = 84

    private static func measure(_ it: MessagesItem, _ m: MessagesThreadModel) -> Block {
        var above: CGFloat = 0, below: CGFloat = 0
        if it.sender != nil { above += 40 }
        if it.replyQuote != nil { above += 46 }
        if !it.tapbacks.isEmpty { above += 46 }
        if it.edited || it.status != nil || it.effect || it.failed { below += 40 }
        let maxW = maxBubble - (m.isGroup && !it.fromMe ? groupIndent : 0)
        switch it.kind {
        case .separator, .unsent:
            return Block(height: 52, main: CGSize(width: 896, height: 52), above: 0, below: 0)
        case .text(let s):
            let lines = wrap(s, bubbleFont, maxW - 2 * hPad, maxLines: 8)
            let w = min(maxW, (lines.map { width($0, bubbleFont) }.max() ?? 0) + 2 * hPad)
            let h = CGFloat(lines.count) * lineH + 2 * vPad
            return Block(height: above + h + below, main: CGSize(width: max(w, 96), height: h), above: above, below: below, lines: lines)
        case .hidden:
            return Block(height: above + 96 + below, main: CGSize(width: 360, height: 96), above: above, below: below)
        case .bigEmoji:
            return Block(height: above + 120 + below, main: CGSize(width: 300, height: 120), above: above, below: below)
        case .photo(let r), .video(let r):
            let img = m.image(r, isVideo(it.kind))
            let a = img.map { CGFloat($0.width) / max(1, CGFloat($0.height)) } ?? r.aspect
            var w: CGFloat = min(maxW, 440), h = w / max(0.3, a)
            if h > 340 { h = 340; w = max(200, h * a) }
            return Block(height: above + h + below, main: CGSize(width: min(maxW, w), height: h), above: above, below: below)
        case .sticker:
            return Block(height: above + 240 + below, main: CGSize(width: 240, height: 240), above: above, below: below)
        case .audio:
            return Block(height: above + 112 + below, main: CGSize(width: min(maxW, 540), height: 112), above: above, below: below)
        case .link(let l, let img):
            let tf = HPType.sf(32, .semibold)
            let lines = wrap(l.title.isEmpty ? l.url : l.title, tf, min(maxW, 560) - 2 * hPad, maxLines: 2)
            let imgH: CGFloat = img == nil ? 0 : 220
            let h = imgH + 30 + CGFloat(lines.count) * 42 + 44 + 24
            return Block(height: above + h + below, main: CGSize(width: min(maxW, 560), height: h), above: above, below: below, lines: lines)
        case .file(let n):
            let w = min(maxW, width(n, bubbleFont) + 2 * hPad + 64)
            return Block(height: above + 100 + below, main: CGSize(width: max(240, w), height: 100), above: above, below: below)
        }
    }

    private static func isVideo(_ k: MessagesItem.Kind) -> Bool { if case .video = k { return true }; return false }

    /// 兩個項目之間：同一串 6、換人 22、時間分隔前後 18
    private static func gapBelow(_ it: MessagesItem, next: MessagesItem) -> CGFloat {
        if case .separator = it.kind { return 10 }
        if case .separator = next.kind { return 26 }
        return it.tail ? 22 : 6
    }

    private static func draw(_ g: CGContext, _ it: MessagesItem, _ b: Block, top: CGFloat, _ m: MessagesThreadModel, index: Int, _ hits: inout Hits) {
        let pad = HPTokens.Space.margin, W: CGFloat = 1024
        let indent: CGFloat = m.isGroup && !it.fromMe ? groupIndent : 0
        let x = it.fromMe ? W - pad - b.main.width : pad + indent
        let main = CGRect(x: x, y: top + b.above, width: b.main.width, height: b.main.height)
        switch it.kind {
        case .separator(let s):
            text(g, s, HPType.sf(HPType.Size.secondary, .semibold), secondary, x: W / 2, y: top + 36, align: .center)
            return
        case .unsent(let s):
            text(g, s, HPType.sf(HPType.Size.secondary, .regular), secondary, x: W / 2, y: top + 36, maxWidth: 896, align: .center)
            return
        default: break
        }
        // 主體上面：寄件人、回覆引用
        var ay = top
        if let s = it.sender {
            text(g, s, smallFont, secondary, x: x + 20, y: ay + 30, maxWidth: 600); ay += 40
        }
        if let q = it.replyQuote {
            let qf = HPType.sf(28, .regular)
            let qs = "↩︎ " + q
            let qw = min(560, width(qs, qf))
            let qx = it.fromMe ? W - pad - qw - 12 : x + 12
            g.setFillColor(HPTokens.tertiary.cgColor)
            g.fill(CGRect(x: it.fromMe ? W - pad - 4 : x, y: ay + 6, width: 4, height: 36))
            text(g, qs, qf, secondary, x: qx, y: ay + 34, maxWidth: 560)
        }
        // 重播：泡泡輕輕放大再回來
        var scale: CGFloat = 1
        if let p = m.pulse, p.row == it.messageRow, !HPMotion.reduceMotion { scale = 1 + 0.12 * sin(.pi * min(1, max(0, p.t))) }   // 減少動態效果：不放大
        g.saveGState()
        if scale != 1 {
            g.translateBy(x: main.midX, y: main.midY); g.scaleBy(x: scale, y: scale); g.translateBy(x: -main.midX, y: -main.midY)
        }
        let fill: NSColor = it.fromMe ? (it.sms ? green : blue) : incoming
        let ink: NSColor = it.fromMe ? .white : label
        switch it.kind {
        case .text:
            fillBubble(g, main, fill, right: it.fromMe, tail: it.tail)
            for (i, line) in b.lines.enumerated() {
                text(g, line, bubbleFont, ink, x: main.minX + hPad, y: main.minY + vPad + CGFloat(i) * lineH + lineH * 0.5 + bubbleFont.capHeight / 2 - 2,
                     maxWidth: main.width - 2 * hPad)
            }
        case .hidden:
            fillBubble(g, main, fill, right: it.fromMe, tail: it.tail)
            if m.revealed.contains(it.messageRow) {
                text(g, L("msg.ink.revealed", "已显示"), bubbleFont, ink, x: main.minX + hPad, y: main.midY + bubbleFont.capHeight / 2)
            } else {
                // 隱形墨水：一片細點
                var seed: UInt64 = UInt64(truncatingIfNeeded: it.messageRow &* 2654435761)
                g.setFillColor(ink.withAlphaComponent(0.55).cgColor)
                for _ in 0..<90 {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let px = main.minX + 24 + CGFloat((seed >> 33) % 1000) / 1000 * (main.width - 48)
                    let py = main.minY + 18 + CGFloat((seed >> 13) % 1000) / 1000 * (main.height - 36)
                    g.fillEllipse(in: CGRect(x: px, y: py, width: 5, height: 5))
                }
            }
            hits.append((.item(index), main))
        case .bigEmoji(let s):
            let f = NSFont.systemFont(ofSize: 112)
            text(g, s, f, label, x: it.fromMe ? main.maxX : main.minX, y: main.maxY - 22, align: it.fromMe ? .right : .left)
        case .photo(let r), .video(let r), .sticker(let r):
            let isSticker: Bool = { if case .sticker = it.kind { return true }; return false }()
            let path = isSticker ? CGPath(rect: main, transform: nil) : continuousRoundedRect(main, radius: 40)
            if let img = m.image(r, isVideo(it.kind)), !r.sensitive {
                g.saveGState(); g.addPath(path); g.clip()
                drawAspectFill(g, img, in: main, fit: isSticker)
                g.restoreGState()
            } else if !isSticker || r.sensitive {
                g.setFillColor(badgeBG.cgColor); g.addPath(path); g.fillPath()
                let gone = !r.sensitive && m.missing(r)
                let sym = r.sensitive ? "eye.slash.fill" : gone ? "icloud.and.arrow.down" : isVideo(it.kind) ? "video.fill" : "photo"
                symbol(g, sym, in: CGRect(x: main.midX - 40, y: main.midY - 40, width: 80, height: 80), color: secondary)
                if r.sensitive || gone {
                    text(g, r.sensitive ? L("msg.sensitive", "可能是敏感内容") : L("msg.missing", "不在这台 Mac 上"), smallFont, secondary,
                         x: main.midX, y: main.midY + 84, maxWidth: main.width - 40, align: .center)
                }
            }
            if isVideo(it.kind) {
                let c = CGRect(x: main.midX - 56, y: main.midY - 56, width: 112, height: 112)
                circle(g, c, NSColor(white: 0, alpha: 0.45))
                symbol(g, "play.fill", in: c.insetBy(dx: 30, dy: 30).offsetBy(dx: 4, dy: 0), color: .white)
            }
            hits.append((.item(index), main))
        case .audio(let r, _):
            fillBubble(g, main, fill, right: it.fromMe, tail: it.tail)
            let playing = m.playing?.id == r.id
            let c = CGRect(x: main.minX + 22, y: main.midY - 34, width: 68, height: 68)
            circle(g, c, it.fromMe ? NSColor(white: 1, alpha: 0.25) : NSColor(white: 0, alpha: 0.08))
            symbol(g, playing ? "pause.fill" : "play.fill", in: c.insetBy(dx: 20, dy: 20).offsetBy(dx: playing ? 0 : 3, dy: 0), color: ink)
            let secs = m.audioSeconds(r)
            let dur = secs.map { String(format: "%d:%02d", Int($0) / 60, Int($0) % 60) } ?? "–:––"
            let df = HPType.sf(30, .medium)
            let dw = width(dur, df)
            text(g, dur, df, ink, x: main.maxX - 30, y: main.midY + df.capHeight / 2, align: .right)
            // 波形：固定的條（沒有解碼聲音），播放進度那一段亮
            let x0 = c.maxX + 22, x1 = main.maxX - 30 - dw - 24
            let n = max(8, Int((x1 - x0) / 13)), prog = playing ? CGFloat(m.playing?.progress ?? 0) : 0
            for i in 0..<n {
                let hh = 14 + 34 * abs(sin(CGFloat(i) * 1.7 + CGFloat(r.id % 7)))
                let bx = x0 + CGFloat(i) * 13
                g.setFillColor(ink.withAlphaComponent(CGFloat(i) / CGFloat(n) < prog ? 1 : 0.45).cgColor)
                g.addPath(CGPath(roundedRect: CGRect(x: bx, y: main.midY - hh / 2, width: 6, height: hh), cornerWidth: 3, cornerHeight: 3, transform: nil)); g.fillPath()
            }
            hits.append((.item(index), main))
        case .link(let l, let imgRef):
            let path = continuousRoundedRect(main, radius: 40)
            g.saveGState(); g.addPath(path); g.clip()
            g.setFillColor(badgeBG.cgColor); g.fill(main)
            var ty = main.minY
            if let r = imgRef {
                let ir = CGRect(x: main.minX, y: main.minY, width: main.width, height: 220)
                if let img = m.image(r, false) { drawAspectFill(g, img, in: ir, fit: false) }
                else { g.setFillColor(incoming.cgColor); g.fill(ir); symbol(g, "link", in: ir.insetBy(dx: ir.width / 2 - 40, dy: 70), color: secondary) }
                ty = ir.maxY
            }
            let tf = HPType.sf(32, .semibold)
            for (i, line) in b.lines.enumerated() { text(g, line, tf, label, x: main.minX + hPad, y: ty + 30 + 32 + CGFloat(i) * 42, maxWidth: main.width - 2 * hPad) }
            text(g, l.site.isEmpty ? l.host : l.site, HPType.sf(28, .regular), secondary, x: main.minX + hPad, y: ty + 30 + CGFloat(b.lines.count) * 42 + 34, maxWidth: main.width - 2 * hPad)
            g.restoreGState()
            hits.append((.item(index), main))
        case .file(let n):
            fillBubble(g, main, fill, right: it.fromMe, tail: it.tail)
            symbol(g, "doc.fill", in: CGRect(x: main.minX + 26, y: main.midY - 24, width: 40, height: 48), color: ink)
            text(g, n, bubbleFont, ink, x: main.minX + 82, y: main.midY + bubbleFont.capHeight / 2, maxWidth: main.width - 82 - hPad)
        case .separator, .unsent: break
        }
        g.restoreGState()
        // 文字、大表情、檔案也進命中表：點了沒事，按住＝念出來（照片等在上面已經加過）
        switch it.kind { case .text, .bigEmoji, .file: hits.append((.item(index), main.insetBy(dx: 0, dy: min(0, (main.height - 88) / 2)))); default: break }
        // VoiceOver：誰、說了什麼（照片、語音、連結講種類）、回應與狀態
        HPAX.note(g, main, it.tappable ? .button : .text, it.fromMe ? L("msg.ax.me", "我") : (it.senderName ?? m.title),
                  value: axValue(it, m), shape: .rounded(40))
        // 群組：對方那一串的最後一則左邊畫頭像
        if let ini = it.senderInitials {
            avatar(g, CGRect(x: pad, y: main.maxY - 64, width: 64, height: 64), image: nil, initials: [ini])
        }
        if !it.tapbacks.isEmpty { drawTapbacks(g, it.tapbacks, anchor: main, fromMe: it.fromMe) }
        // 主體下面：已編輯／重播／狀態（同一行，靠泡泡那一側）
        var notes: [(String, NSColor)] = []
        if it.edited { notes.append((L("msg.edited", "已编辑"), blue)) }
        if it.effect { notes.append(("↺ " + L("msg.replay", "重播"), blue)) }
        if it.failed { notes.append((L("msg.status.failed", "未送达"), HPTokens.red)) }
        else if let s = it.status { notes.append((s, secondary)) }
        if !notes.isEmpty {
            let f = smallFont
            var nx = it.fromMe ? main.maxX : main.minX + 8
            let ny = main.maxY + 34
            for (s, c) in (it.fromMe ? notes.reversed() : notes) {
                let w = width(s, f)
                if it.fromMe { text(g, s, f, c, x: nx, y: ny, align: .right); nx -= w + 22 }
                else { text(g, s, f, c, x: nx, y: ny); nx += w + 22 }
            }
            if it.effect { hits.append((.item(index), CGRect(x: main.minX, y: main.maxY - 48, width: max(88, main.width), height: 88))) }
        }
    }

    static func axValue(_ it: MessagesItem, _ m: MessagesThreadModel) -> String {
        var parts: [String] = []
        switch it.kind {
        case .text(let s), .bigEmoji(let s): parts.append(s)
        case .photo: parts.append(L("msg.ax.photo", "照片"))
        case .video: parts.append(L("msg.ax.video", "视频"))
        case .sticker: parts.append(L("msg.ax.sticker", "贴纸"))
        case .audio: parts.append(L("msg.audio", "语音信息"))
        case .link(let l, _): parts.append(l.title.isEmpty ? l.host : l.title + ", " + l.host)
        case .file(let n): parts.append(n)
        case .hidden: parts.append(m.revealed.contains(it.messageRow) ? L("msg.ink.revealed", "已显示") : L("msg.effect.ink", "隐形墨水"))
        case .unsent(let s), .separator(let s): parts.append(s)
        }
        if let q = it.replyQuote { parts.append(String(format: L("msg.ax.replyTo", "回复：%@"), q)) }
        if !it.tapbacks.isEmpty { parts.append(it.tapbacks.map(glyph).joined()) }
        if it.edited { parts.append(L("msg.edited", "已编辑")) }
        if it.failed { parts.append(L("msg.status.failed", "未送达")) } else if let s = it.status { parts.append(s) }
        return parts.joined(separator: ", ")
    }

    private static func loadingState(_ g: CGContext, y: CGFloat) {
        HPComponents.spinner(g, in: CGRect(x: 512 - 32, y: y, width: 64, height: 64), ink: secondary)
        text(g, L("msg.loading", "正在载入…"), HPType.sf(HPType.Size.secondary, .regular), secondary, x: 512, y: y + 120, align: .center)
    }

    /// iOS 18 起的 Tapback：泡泡上緣角落的圓角標（對方的泡泡在右上、自己的在左上），自己按的是藍底
    private static func drawTapbacks(_ g: CGContext, _ taps: [MsgTapback], anchor r: CGRect, fromMe: Bool) {
        let shown = Array(taps.suffix(3)), d: CGFloat = 76
        for (i, t) in shown.enumerated() {
            let off = CGFloat(shown.count - 1 - i) * 56   // 最新的在最靠泡泡角的位置、畫在最上面
            let cx = fromMe ? r.minX + 6 - off : r.maxX - 6 + off
            let c = CGRect(x: cx - d / 2, y: r.minY - 46, width: d, height: d)
            circle(g, c.insetBy(dx: -5, dy: -5), background)
            circle(g, c, t.fromMe ? blue : badgeBG)
            text(g, glyph(t), NSFont.systemFont(ofSize: 40), label, x: c.midX, y: c.midY + 15, align: .center)
        }
    }

    static func glyph(_ t: MsgTapback) -> String {
        switch t.kind {
        case .love: return "❤️"; case .like: return "👍"; case .dislike: return "👎"; case .laugh: return "😂"
        case .emphasis: return "‼️"; case .question: return "❓"; case .emoji: return t.emoji ?? "🙂"
        }
    }

    // MARK: 新訊息

    private static func drawCompose(_ g: CGContext, _ m: MessagesComposeModel, _ hits: inout Hits) {
        let pad = HPTokens.Space.margin, W: CGFloat = 1024
        drawHeader(g, title: L("msg.new", "新信息"), inShell: true, &hits)
        // 收件人列
        let lf = HPType.sf(HPType.Size.list, .regular), sf = HPType.sf(HPType.Size.list, .semibold)
        let to = L("msg.to", "收件人：")
        let rowY = HPTokens.contentTop
        text(g, to, lf, secondary, x: pad, y: rowY + 52)
        let tx = pad + width(to, lf) + 12
        if let r = m.recipient {
            let chipR = CGRect(x: tx, y: rowY + 4, width: min(W - pad - tx, width(r, sf) + 48), height: 70)
            g.setFillColor(blue.withAlphaComponent(0.14).cgColor); g.addPath(CGPath(roundedRect: chipR, cornerWidth: 35, cornerHeight: 35, transform: nil)); g.fillPath()
            text(g, r, sf, blue, x: chipR.minX + 24, y: rowY + 52, maxWidth: chipR.width - 48)
            hits.append((.clearRecipient, chipR.insetBy(dx: 0, dy: -9)))
        } else {
            text(g, m.query.isEmpty ? L("msg.to.placeholder", "说出或打出名字") : m.query, lf, m.query.isEmpty ? HPTokens.tertiary : label, x: tx, y: rowY + 52, maxWidth: W - pad - tx)
        }
        g.setFillColor(HPTokens.separator.cgColor); g.fill(CGRect(x: pad, y: rowY + 90, width: W - 2 * pad, height: 2))
        if m.recipient != nil {
            _ = drawInputBar(g, speakTitle: L("msg.speak", "用说的"), &hits)
            return
        }
        // 還在選：建議（最近的對話、通訊錄符合的人），底下是「說名字」「打名字」
        let by = drawInputBar(g, speakTitle: L("msg.to.say", "说名字"), &hits, speak: .sayName, type: .typeName, emoji: false)
        var y = rowY + 110
        let rowH: CGFloat = 132, av: CGFloat = 92
        let df = HPType.sf(HPType.Size.secondary, .regular)
        if m.suggestions.isEmpty {
            text(g, L("msg.to.none", "没有符合的联系人"), df, secondary, x: W / 2, y: y + 120, align: .center)
        }
        for (i, s) in m.suggestions.enumerated() where y + rowH <= by - 20 {
            let avR = CGRect(x: pad, y: y + (rowH - av) / 2, width: av, height: av)
            avatar(g, avR, image: s.avatar, initials: [s.initials])
            text(g, s.name, sf, label, x: avR.maxX + 28, y: y + 58, maxWidth: W - pad - avR.maxX - 28)
            text(g, s.detail, df, secondary, x: avR.maxX + 28, y: y + 100, maxWidth: W - pad - avR.maxX - 28)
            hits.append((.suggestion(i), CGRect(x: 0, y: y, width: W, height: rowH)))
            y += rowH
        }
    }

    // MARK: 繪製工具

    private static func circle(_ g: CGContext, _ r: CGRect, _ c: NSColor) { g.setFillColor(c.cgColor); g.fillEllipse(in: r) }

    /// 頭像：照片（圓形裁切）；沒有就 Apple 灰色縮寫圓；兩個縮寫＝群組（左上、右下兩個小圓）
    static func avatar(_ g: CGContext, _ r: CGRect, image: CGImage?, initials: [String]) {
        if let img = image {
            g.saveGState(); g.addEllipse(in: r); g.clip(); drawAspectFill(g, img, in: r, fit: false); g.restoreGState()
            return
        }
        if initials.count >= 2 {
            let d = r.width * 0.66
            Monogram.draw(g, CGRect(x: r.minX, y: r.minY, width: d, height: d), initials: initials[0])
            let b = CGRect(x: r.maxX - d, y: r.maxY - d, width: d, height: d)
            circle(g, b.insetBy(dx: -4, dy: -4), background)
            Monogram.draw(g, b, initials: initials[1])
        } else if let ini = initials.first, ini.contains(where: \.isLetter) {
            Monogram.draw(g, r, initials: ini)
        } else {
            // 沒有名字（只有號碼的陌生人）：灰圓裡一個人形，跟 iPhone 一樣
            Monogram.draw(g, r, initials: " ")
            symbol(g, "person.fill", in: r.insetBy(dx: r.width * 0.26, dy: r.height * 0.26), color: .white)
        }
    }

    /// 圖畫進框（畫布左上原點，要翻回來）：fill＝裁切填滿；fit＝整張放進去（貼圖）
    static func drawAspectFill(_ g: CGContext, _ img: CGImage, in r: CGRect, fit: Bool) {
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let s = fit ? min(r.width / iw, r.height / ih) : max(r.width / iw, r.height / ih)
        let dst = CGRect(x: r.midX - iw * s / 2, y: r.midY - ih * s / 2, width: iw * s, height: ih * s)
        g.saveGState(); g.translateBy(x: 0, y: dst.minY + dst.maxY); g.scaleBy(x: 1, y: -1)
        g.interpolationQuality = .high; g.draw(img, in: dst); g.restoreGState()
    }

    /// 泡泡與尾巴分開填（兩個子路徑方向相反時 nonzero 會挖洞）
    static func fillBubble(_ g: CGContext, _ r: CGRect, _ c: NSColor, right: Bool, tail: Bool) {
        g.setFillColor(c.cgColor)
        g.addPath(continuousRoundedRect(r, radius: min(42, r.height / 2))); g.fillPath()
        if tail { g.addPath(tailPath(r, right: right)); g.fillPath() }
    }

    /// iOS 的鉤形尾巴：從泡泡下緣往外勾出去
    static func tailPath(_ r: CGRect, right: Bool) -> CGPath {
        let p = CGMutablePath()
        let s: CGFloat = right ? 1 : -1, x = right ? r.maxX : r.minX, y = r.maxY
        // 從側邊（離底 44）直直往下、在角落往外勾出尖端，再沿底邊收回去；裡面那塊把圓角的缺口補滿
        p.move(to: CGPoint(x: x - s * 1, y: y - 44))
        p.addCurve(to: CGPoint(x: x + s * 15, y: y + 1), control1: CGPoint(x: x - s * 1, y: y - 16), control2: CGPoint(x: x + s * 5, y: y - 3))
        p.addCurve(to: CGPoint(x: x - s * 34, y: y - 3), control1: CGPoint(x: x - s * 4, y: y + 3), control2: CGPoint(x: x - s * 20, y: y + 1))
        p.addLine(to: CGPoint(x: x - s * 34, y: y - 44))
        p.closeSubpath()
        return p
    }

    /// SF Symbol（單色），r 是左上原點的框；符號等比置中（同 Face.drawSymbol，這裡沒有 Face）
    static func symbol(_ g: CGContext, _ name: String, in r: CGRect, color: NSColor, weight: NSFont.Weight = .semibold) {
        let cfg = NSImage.SymbolConfiguration(pointSize: r.height, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let s = img.size, k = min(r.width / max(1, s.width), r.height / max(1, s.height))
        let dst = CGRect(x: r.midX - s.width * k / 2, y: r.midY - s.height * k / 2, width: s.width * k, height: s.height * k)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: g, flipped: true)
        img.draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 控制層的圓鈕／膠囊：有殼層的玻璃就用玻璃（玻璃上的符號與字放在 content，正式的 GlassPass 會延到幀尾才畫玻璃）
    private static func controlCircle(_ g: CGContext, _ r: CGRect, content: @escaping (CGContext) -> Void) {
        if controlGlass?(g, CGPath(ellipseIn: r, transform: nil), "msg.o|\(r)", content) != true { circle(g, r, controlFill); content(g) }
    }
    private static func controlPill(_ g: CGContext, _ r: CGRect, content: @escaping (CGContext) -> Void) {
        let path = CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
        if controlGlass?(g, path, "msg.p|\(r)", content) != true { pill(g, r, fill: controlFill); content(g) }
    }
    private static func pill(_ g: CGContext, _ r: CGRect, fill: NSColor) {
        g.setFillColor(fill.cgColor)
        g.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)); g.fillPath()
    }

    /// 設計稿 24×24 的愛心
    static func heartPath(in r: CGRect) -> CGPath {
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x / 24 * r.width, y: r.minY + y / 24 * r.height) }
        let p = CGMutablePath()
        p.move(to: P(12, 21))
        p.addCurve(to: P(4, 10), control1: P(12, 21), control2: P(4, 15.8))
        p.addCurve(to: P(12, 7.2), control1: P(4, 6.0), control2: P(9.2, 4.2))
        p.addCurve(to: P(20, 10), control1: P(14.8, 4.2), control2: P(20, 6.0))
        p.addCurve(to: P(12, 21), control1: P(20, 15.8), control2: P(12, 21))
        p.closeSubpath()
        return p
    }

    enum Align { case left, center, right }

    @discardableResult
    static func text(_ g: CGContext, _ s: String, _ font: NSFont, _ color: NSColor, x: CGFloat, y: CGFloat,
                     maxWidth: CGFloat? = nil, align: Align = .left) -> CGFloat {
        guard !s.isEmpty else { return 0 }
        let attrs = Typo.attributes(font, color: color)
        let attr = NSAttributedString(string: s, attributes: attrs)
        var line = CTLineCreateWithAttributedString(attr)
        var w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let trailing = (attrs[.kern] as? CGFloat) ?? 0   // 最後一字後面那份字距不算（跟 Typo.width 一致，量好的泡泡不會被截）
        if let mw = maxWidth, w - trailing > mw + 0.5 {
            let tok = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: Typo.attributes(font, color: color)))
            if let t = CTLineCreateTruncatedLine(line, Double(mw), .end, tok) { line = t; w = CGFloat(CTLineGetTypographicBounds(t, nil, nil, nil)) }
        }
        let ox = align == .left ? x : align == .center ? x - w / 2 : x - w
        g.saveGState()
        g.translateBy(x: ox, y: y); g.scaleBy(x: 1, y: -1)
        g.textPosition = .zero; CTLineDraw(line, g)
        g.restoreGState()
        return w
    }

    static func width(_ s: String, _ font: NSFont) -> CGFloat { Typo.width(s, font) }

    /// 折行（CTTypesetter，中文逐字、英文按詞；保留使用者的換行）。放不下 maxLines 時，最後一行放「剩下全部」，畫的時候再截斷加「…」
    static func wrap(_ s: String, _ font: NSFont, _ maxWidth: CGFloat, maxLines: Int) -> [String] {
        var out: [String] = []
        let paragraphs = s.components(separatedBy: "\n")
        for (pi, para) in paragraphs.enumerated() {
            let attr = NSAttributedString(string: para, attributes: Typo.attributes(font))
            let ts = CTTypesetterCreateWithAttributedString(attr)
            let ns = para as NSString
            var start = 0
            if ns.length == 0 { out.append("") }
            while start < ns.length {
                if out.count == maxLines - 1 {
                    let rest = ([ns.substring(from: start)] + paragraphs.dropFirst(pi + 1)).joined(separator: " ")
                    out.append(rest); return out
                }
                let n = CTTypesetterSuggestLineBreak(ts, start, Double(maxWidth))
                if n <= 0 { out.append(ns.substring(from: start)); break }
                out.append(ns.substring(with: NSRange(location: start, length: n)).trimmingCharacters(in: .whitespaces))
                start += n
            }
            if out.count >= maxLines { return Array(out.prefix(maxLines)) }
        }
        while out.count > 1, out.last == "" { out.removeLast() }
        return out.isEmpty ? [""] : out
    }
}
