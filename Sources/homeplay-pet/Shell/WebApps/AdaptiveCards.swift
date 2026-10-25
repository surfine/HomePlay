// 2.0 Web App 的小工具：manifest 的 widgets[]（Microsoft PWA Widgets）＋ Adaptive Cards 範本（docs/plans/webapps.md）。
//
// 只照 adaptivecards.io 的 schema 自己寫一個子集（沒有拷任何程式碼）：
// - 範本：`${a.b[0]}` 取值（整個字串就是一個 ${…} 時保留型別）、`$data`（陣列＝重複這個元素、物件＝換範圍）、`$when`（真假）、
//   `$root`、`$index`、`!` 反向。
// - 元素：TextBlock（size、weight、color、isSubtle、wrap、maxLines、horizontalAlignment）、Image（size、style person）、
//   Container、ColumnSet／Column（auto、stretch、比例）、FactSet、ActionSet 與卡片的 actions（畫成膠囊；點小工具＝打開 Web App）。
// 字、顏色、框走 HPDS（SF Pro、系統色、小工具框、清透／染色時用 WidgetInk）。

import AppKit
import WebKit

// MARK: - 範本（純函數）

enum ACTemplate {
    struct Scope { var data: Any; var root: Any; var index: Int? }

    static func bind(_ template: Any, data: Any) -> Any {
        expand(template, Scope(data: data, root: data, index: nil)).first ?? [:]
    }

    /// 一個值展開成 0…n 個（$when 不成立＝0 個；$data 是陣列＝n 個）
    static func expand(_ v: Any, _ s: Scope) -> [Any] {
        if let d = v as? [String: Any] {
            var scopes = [s]
            if let dv = d["$data"] {
                let val: Any? = (dv as? String).map { interpolate($0, s) } ?? dv
                if let arr = val as? [Any] { scopes = arr.enumerated().map { Scope(data: $0.element, root: s.root, index: $0.offset) } }
                else if let val { scopes = [Scope(data: val, root: s.root, index: s.index)] }
                else { scopes = [] }
            }
            var out: [Any] = []
            for sc in scopes {
                if let w = d["$when"] {
                    let ok = (w as? String).map { truthy(interpolate($0, sc)) } ?? truthy(w)
                    if !ok { continue }
                }
                var o: [String: Any] = [:]
                for (k, x) in d where k != "$data" && k != "$when" {
                    if let arr = x as? [Any] { o[k] = arr.flatMap { expand($0, sc) } }
                    else if let first = expand(x, sc).first { o[k] = first }
                }
                out.append(o)
            }
            return out
        }
        if let a = v as? [Any] { return [a.flatMap { expand($0, s) }] }
        if let str = v as? String { return [interpolate(str, s) ?? ""] }
        return [v]
    }

    /// "${x}" 整個＝x 的值（保留型別）；混在字裡＝換成字
    static func interpolate(_ str: String, _ s: Scope) -> Any? {
        guard str.contains("${") else { return str }
        if str.hasPrefix("${"), str.hasSuffix("}"), str.dropFirst(2).firstIndex(of: "}") == str.index(before: str.endIndex) {
            return eval(String(str.dropFirst(2).dropLast()), s)
        }
        var out = "", rest = Substring(str)
        while let open = rest.range(of: "${") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].firstIndex(of: "}") else { out += rest[open.lowerBound...]; rest = ""; break }
            out += text(eval(String(rest[open.upperBound..<close]), s))
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    static func eval(_ e: String, _ s: Scope) -> Any? {
        var t = e.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("!") { return !truthy(eval(String(t.dropFirst()), s)) }
        if (t.hasPrefix("'") && t.hasSuffix("'") && t.count >= 2) || (t.hasPrefix("\"") && t.hasSuffix("\"") && t.count >= 2) { return String(t.dropFirst().dropLast()) }
        if let n = Double(t) { return n }
        if t == "true" { return true }
        if t == "false" { return false }
        var cur: Any? = s.data
        if t == "$index" { return s.index.map { Double($0) } }
        if t.hasPrefix("$root") { cur = s.root; t = String(t.dropFirst(5)) }
        else if t.hasPrefix("$data") { t = String(t.dropFirst(5)) }
        // a.b[0].c
        var key = ""
        func step() { if !key.isEmpty { cur = (cur as? [String: Any])?[key]; key = "" } }
        var i = t.startIndex
        while i < t.endIndex {
            let c = t[i]
            if c == "." { step() }
            else if c == "[" {
                step()
                guard let close = t[i...].firstIndex(of: "]"), let n = Int(t[t.index(after: i)..<close]) else { return nil }
                let arr = cur as? [Any]
                cur = arr.flatMap { n >= 0 && n < $0.count ? $0[n] : nil }
                i = close
            } else { key.append(c) }
            i = t.index(after: i)
        }
        step()
        return cur
    }

    static func truthy(_ v: Any?) -> Bool {
        switch v {
        case nil: return false
        case let b as Bool: return b
        case let n as NSNumber: return n.doubleValue != 0
        case let d as Double: return d != 0
        case let s as String: return !s.isEmpty && s != "false"
        case let a as [Any]: return !a.isEmpty
        case is NSNull: return false
        default: return true
        }
    }
    static func text(_ v: Any?) -> String {
        switch v {
        case nil, is NSNull: return ""
        case let s as String: return s
        case let b as Bool: return b ? "true" : "false"
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            let d = n.doubleValue
            return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case let d as Double: return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        default: return "\(v!)"
        }
    }
}

// MARK: - 卡片結構（純函數）

indirect enum ACNode: Equatable {
    case text(String, size: String, weight: String, color: String, subtle: Bool, wrap: Bool, maxLines: Int, align: String, spacing: String)
    case image(URL, size: String, person: Bool, spacing: String)
    case container([ACNode], spacing: String)
    case columns([ACColumn], spacing: String)
    case facts([ACFact], spacing: String)
    case actions([String], spacing: String)
}
struct ACColumn: Equatable { var width: String; var items: [ACNode] }
struct ACFact: Equatable { var title: String; var value: String }

struct ACCard: Equatable {
    var body: [ACNode]
    var actions: [String]

    static func parse(_ j: Any) -> ACCard? {
        guard let o = j as? [String: Any], (o["type"] as? String) == "AdaptiveCard" else { return nil }
        let body = nodes(o["body"])
        let acts = ((o["actions"] as? [[String: Any]]) ?? []).compactMap { $0["title"] as? String }.filter { !$0.isEmpty }
        return ACCard(body: body, actions: Array(acts.prefix(3)))
    }
    static func nodes(_ v: Any?) -> [ACNode] { ((v as? [Any]) ?? []).compactMap(node) }
    static func node(_ v: Any) -> ACNode? {
        guard let o = v as? [String: Any], let type = o["type"] as? String else { return nil }
        if (o["isVisible"] as? Bool) == false { return nil }
        let sp = (o["spacing"] as? String)?.lowercased() ?? "default"
        func s(_ k: String, _ d: String) -> String { (o[k] as? String)?.lowercased() ?? d }
        switch type {
        case "TextBlock", "RichTextBlock":
            var t = ACTemplate.text(o["text"])
            if type == "RichTextBlock" { t = ((o["inlines"] as? [Any]) ?? []).map { ($0 as? String) ?? ACTemplate.text(($0 as? [String: Any])?["text"]) }.joined() }
            guard !t.isEmpty else { return nil }
            return .text(t, size: s("size", "default"), weight: s("weight", "default"), color: s("color", "default"), subtle: (o["isSubtle"] as? Bool) ?? false,
                         wrap: (o["wrap"] as? Bool) ?? false, maxLines: (o["maxLines"] as? Int) ?? 0, align: s("horizontalalignment", s("horizontalAlignment", "left")), spacing: sp)
        case "Image":
            guard let u = (o["url"] as? String).flatMap(URL.init(string:)), WebManifestParser.allowedScheme(u) else { return nil }
            return .image(u, size: s("size", "medium"), person: s("style", "default") == "person", spacing: sp)
        case "Container":
            let items = nodes(o["items"])
            return items.isEmpty ? nil : .container(items, spacing: sp)
        case "ColumnSet":
            let cols = ((o["columns"] as? [Any]) ?? []).compactMap { c -> ACColumn? in
                guard let co = c as? [String: Any] else { return nil }
                let w: String = (co["width"] as? String)?.lowercased() ?? (co["width"] as? NSNumber).map { "\($0.doubleValue)" } ?? "stretch"
                return ACColumn(width: w, items: nodes(co["items"]))
            }
            return cols.isEmpty ? nil : .columns(cols, spacing: sp)
        case "FactSet":
            let fs = ((o["facts"] as? [[String: Any]]) ?? []).map { ACFact(title: ACTemplate.text($0["title"]), value: ACTemplate.text($0["value"])) }
            return fs.isEmpty ? nil : .facts(fs, spacing: sp)
        case "ActionSet":
            let a = ((o["actions"] as? [[String: Any]]) ?? []).compactMap { $0["title"] as? String }.filter { !$0.isEmpty }
            return a.isEmpty ? nil : .actions(Array(a.prefix(3)), spacing: sp)
        default: return nil
        }
    }
}

// MARK: - 排版與畫（1024 畫布；字照 iOS 小工具的 pt × SBK.K）

struct ACInk { var primary: NSColor; var secondary: NSColor; var accent: NSColor; var accented: Bool }

enum ACRender {
    static let K = SBK.K
    static func font(_ size: String, _ weight: String) -> NSFont {
        let pt: CGFloat = ["small": 12, "medium": 17, "large": 21, "extralarge": 26][size] ?? 14
        let w: NSFont.Weight = weight == "bolder" ? .semibold : (weight == "lighter" ? .light : .regular)
        return HPType.sf(pt * K, w)
    }
    static func gap(_ s: String) -> CGFloat { ["none": 0, "small": 3, "medium": 12, "large": 18, "extralarge": 24, "padding": 12][s].map { $0 * K } ?? 6 * K }
    static func imageSide(_ s: String) -> CGFloat { (["small": 28, "large": 72, "stretch": 72][s] ?? 44) * K }
    static func color(_ c: String, _ ink: ACInk, subtle: Bool) -> NSColor {
        if ink.accented { return c == "accent" || c == "good" || c == "warning" || c == "attention" ? ink.accent : (subtle ? ink.secondary : ink.primary) }
        let base: NSColor
        switch c {
        case "accent": base = HPTokens.blue
        case "good": base = HPTokens.green
        case "warning": base = HPTokens.orange
        case "attention": base = HPTokens.red
        case "light": base = .white
        case "dark": base = .black
        default: base = ink.primary
        }
        return subtle ? (c == "default" ? ink.secondary : base.withAlphaComponent(0.65)) : base
    }
    static func spacing(_ n: ACNode) -> String {
        switch n {
        case .text(_, _, _, _, _, _, _, _, let s), .image(_, _, _, let s), .container(_, let s), .columns(_, let s), .facts(_, let s), .actions(_, let s): return s
        }
    }
    static func lines(_ t: String, _ f: NSFont, _ w: CGFloat, wrap: Bool, maxLines: Int) -> [String] {
        let n = wrap ? (maxLines > 0 ? maxLines : 6) : 1
        let ls = Face.photosWrap(t, f, w, maxLines: n)
        return ls.map { Face.clipped($0, f, w) }
    }

    /// 量高度
    static func height(_ nodes: [ACNode], _ w: CGFloat) -> CGFloat {
        var h: CGFloat = 0
        for (i, n) in nodes.enumerated() { h += (i == 0 ? 0 : gap(spacing(n))) + height(n, w) }
        return h
    }
    static func height(_ n: ACNode, _ w: CGFloat) -> CGFloat {
        switch n {
        case .text(let t, let size, let weight, _, _, let wrap, let maxLines, _, _):
            let f = font(size, weight)
            return CGFloat(lines(t, f, w, wrap: wrap, maxLines: maxLines).count) * f.pointSize * 1.22
        case .image(_, let size, _, _): return imageSide(size)
        case .container(let items, _): return height(items, w)
        case .columns(let cols, _): return zip(cols, widths(cols, w)).map { height($0.0.items, $0.1) }.max() ?? 0
        case .facts(let fs, _): return CGFloat(fs.count) * font("default", "default").pointSize * 1.3
        case .actions: return 32 * K
        }
    }
    /// 欄寬：auto＝內容自然寬（上限一半）、stretch＝分剩下的、數字＝照比例
    static func widths(_ cols: [ACColumn], _ w: CGFloat) -> [CGFloat] {
        let g = 8 * K, avail = w - g * CGFloat(max(0, cols.count - 1))
        var fixed: [CGFloat?] = cols.map { c in
            guard c.width == "auto" else { return nil }
            return min(avail / 2, natural(c.items))
        }
        let used = fixed.compactMap { $0 }.reduce(0, +)
        let weights = cols.map { c -> CGFloat in c.width == "auto" ? 0 : (c.width == "stretch" ? 1 : CGFloat(Double(c.width.replacingOccurrences(of: "px", with: "")) ?? 1)) }
        let total = max(0.0001, weights.reduce(0, +))
        for i in cols.indices where fixed[i] == nil { fixed[i] = max(0, avail - used) * weights[i] / total }
        return fixed.map { $0 ?? 0 }
    }
    static func natural(_ items: [ACNode]) -> CGFloat {
        items.map { n -> CGFloat in
            switch n {
            case .text(let t, let size, let weight, _, _, _, _, _, _): return Typo.width(t, font(size, weight)) + 2
            case .image(_, let size, _, _): return imageSide(size)
            case .container(let i, _): return natural(i)
            default: return 120 * K
            }
        }.max() ?? 0
    }

    /// 畫（y 往下）；回傳畫到哪
    @discardableResult
    static func draw(_ g: CGContext, _ face: Face, _ nodes: [ACNode], x: CGFloat, y: CGFloat, w: CGFloat, ink: ACInk, image: (URL) -> CGImage?) -> CGFloat {
        var y = y
        for (i, n) in nodes.enumerated() {
            if i > 0 { y += gap(spacing(n)) }
            draw(g, face, n, x: x, y: y, w: w, ink: ink, image: image)
            y += height(n, w)
        }
        return y
    }
    static func draw(_ g: CGContext, _ face: Face, _ n: ACNode, x: CGFloat, y: CGFloat, w: CGFloat, ink: ACInk, image: (URL) -> CGImage?) {
        switch n {
        case .text(let t, let size, let weight, let c, let subtle, let wrap, let maxLines, let align, _):
            let f = font(size, weight), lh = f.pointSize * 1.22, col = color(c, ink, subtle: subtle)
            for (i, l) in lines(t, f, w, wrap: wrap, maxLines: maxLines).enumerated() {
                let lw = Typo.width(l, f)
                let lx = align == "center" ? x + (w - lw) / 2 : (align == "right" ? x + w - lw : x)
                face.drawLeft(g, l, font: f, x: lx, y: y + CGFloat(i) * lh + f.ascender * 0.98, color: col)
            }
        case .image(let u, let size, let person, _):
            let s = imageSide(size), r = CGRect(x: x, y: y, width: s, height: s)
            g.saveGState()
            g.addPath(person ? CGPath(ellipseIn: r, transform: nil) : continuousRoundedRect(r, radius: s * 0.18)); g.clip()
            if let img = image(u) { face.drawUpright(g, img, in: r) } else { g.setFillColor(ink.secondary.withAlphaComponent(0.25).cgColor); g.fill(r) }
            g.restoreGState()
        case .container(let items, _):
            draw(g, face, items, x: x, y: y, w: w, ink: ink, image: image)
        case .columns(let cols, _):
            var cx = x
            for (c, cw) in zip(cols, widths(cols, w)) {
                draw(g, face, c.items, x: cx, y: y, w: cw, ink: ink, image: image)
                cx += cw + 8 * K
            }
        case .facts(let fs, _):
            let f = font("default", "default"), bf = font("default", "bolder"), lh = f.pointSize * 1.3
            let tw = min(w * 0.45, (fs.map { Typo.width($0.title, bf) }.max() ?? 0) + 10 * K)
            for (i, fa) in fs.enumerated() {
                let by = y + CGFloat(i) * lh + f.ascender
                face.drawLeft(g, Face.clipped(fa.title, bf, tw - 6 * K), font: bf, x: x, y: by, color: ink.secondary)
                face.drawLeft(g, Face.clipped(fa.value, f, w - tw), font: f, x: x + tw, y: by, color: ink.primary)
            }
        case .actions(let titles, _):
            drawButtons(g, face, titles, x: x, y: y, w: w, ink: ink)
        }
    }
    static func drawButtons(_ g: CGContext, _ face: Face, _ titles: [String], x: CGFloat, y: CGFloat, w: CGFloat, ink: ACInk) {
        let h = 32 * K, gp = 6 * K, n = CGFloat(max(1, titles.count))
        let bw = (w - gp * (n - 1)) / n
        for (i, t) in titles.enumerated() {
            let r = CGRect(x: x + CGFloat(i) * (bw + gp), y: y, width: bw, height: h)
            g.addPath(HPComponents.capsulePath(r)); g.setFillColor((ink.accented ? ink.accent.withAlphaComponent(0.25) : ink.accent.withAlphaComponent(0.15)).cgColor); g.fillPath()
            let f = HPType.fitted(t, size: 13 * K, weight: .semibold, maxWidth: bw - 16 * K)
            face.drawLeft(g, t, font: f, x: r.midX - Typo.width(t, f) / 2, y: r.midY + f.capHeight / 2, color: ink.accent)
        }
    }
}

// MARK: - 小工具資料：抓範本與資料（用這個 Web App 自己的 cookie；只抓同源）、圖片快取

enum WebAppWidgets {
    static let iconTag = "_icon"
    private struct Entry { var card: ACCard?; var fetched: Double; var loading: Bool }
    nonisolated(unsafe) private static var entries: [String: Entry] = [:]
    nonisolated(unsafe) private static var images: [URL: CGImage] = [:]
    nonisolated(unsafe) private static var imageLoading: Set<URL> = []

    /// 綁好的卡；沒有（還在抓、抓不到）回 nil＝畫圖示小工具
    static func card(_ app: WebApp, tag: String, now: Double = CACurrentMediaTime()) -> ACCard? {
        guard tag != iconTag, let def = app.widgets.first(where: { $0.tag == tag }), let t = def.template else { return nil }
        let key = "\(app.uuid)|\(tag)"
        let e = entries[key]
        let every = max(300, def.update ?? 900)
        if e == nil || (!(e!.loading) && now - e!.fetched > every) { fetch(app, def, template: t, key: key) }
        return e?.card
    }

    private static func fetch(_ app: WebApp, _ def: WebAppWidgetDef, template: URL, key: String) {
        entries[key] = Entry(card: entries[key]?.card, fetched: CACurrentMediaTime(), loading: true)
        cookieHeaders(app) { cookies in
            func get(_ u: URL, _ done: @escaping (Data?) -> Void) {
                guard app.inScope(u) || WebManifestParser.sameOrigin(u, app.start ?? u) else { done(nil); return }
                var r = URLRequest(url: u); r.cachePolicy = .reloadIgnoringLocalCacheData
                for (k, v) in HTTPCookie.requestHeaderFields(with: cookies.filter { match($0, u) }) { r.setValue(v, forHTTPHeaderField: k) }
                r.setValue("application/json", forHTTPHeaderField: "Accept")
                WebFetch.session.dataTask(with: r) { d, resp, _ in
                    let ok = ((resp as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2 && (d?.count ?? 0) <= 512 << 10
                    DispatchQueue.main.async { done(ok ? d : nil) }
                }.resume()
            }
            get(template) { td in
                guard let td, let tj = try? JSONSerialization.jsonObject(with: td) else { finish(key, nil); return }
                guard let du = def.data else { finish(key, ACCard.parse(ACTemplate.bind(tj, data: [String: Any]()))); return }
                get(du) { dd in
                    let data = dd.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [String: Any]()
                    finish(key, ACCard.parse(ACTemplate.bind(tj, data: data)))
                }
            }
        }
    }
    private static func finish(_ key: String, _ card: ACCard?) {
        entries[key] = Entry(card: card ?? entries[key]?.card, fetched: CACurrentMediaTime(), loading: false)
        redraw()
    }
    static var pending: Bool { entries.values.contains { $0.loading } || !imageLoading.isEmpty }
    static func redraw() {
        Shell.homeLayer = nil; SB.pageCache.removeAll()
        (NSApp.delegate as? AppDelegate)?.view?.face.forceDirty = true
    }

    /// 這個 Web App 自己的 cookie（快照：沒有）
    private static func cookieHeaders(_ app: WebApp, _ done: @escaping ([HTTPCookie]) -> Void) {
        guard !WebAppStore.shared.demoOnly else { done([]); return }
        WebAppData.store(app.uuid).httpCookieStore.getAllCookies { done($0) }
    }
    static func match(_ c: HTTPCookie, _ u: URL) -> Bool {
        guard let host = u.host?.lowercased() else { return false }
        let d = c.domain.lowercased(), bare = d.hasPrefix(".") ? String(d.dropFirst()) : d
        guard host == bare || host.hasSuffix("." + bare) else { return false }
        if c.isSecure, u.scheme?.lowercased() != "https" { return false }
        return u.path.isEmpty ? c.path == "/" : u.path.hasPrefix(c.path)
    }

    static func image(_ u: URL) -> CGImage? {
        if let i = images[u] { return i }
        guard !imageLoading.contains(u) else { return nil }
        imageLoading.insert(u)
        WebFetch.get(u, limit: 2 << 20) { d in
            imageLoading.remove(u)
            if let d, let img = WebFetch.image(d) { images[u] = img; redraw() }
        }
        return nil
    }

    /// 主畫面長按「加入小工具」：卡片小工具預設中（4×2），圖示小工具預設小（2×2）；放在這一頁最前面（SpringBoard 的 addWidget）
    static func addToHome(_ app: WebApp, tag: String) {
        let size: SBWidgetSize = tag == iconTag || app.widgets.isEmpty ? .small : .medium
        var l = SB.layout
        l.addWidget(.widget(SBWidget(id: SBStore.newID("w"), kind: .webApp, size: size, config: ["app": app.appID, "tag": tag])), page: SB.pageIndex)
        SB.layout = l; SB.commit()
        log("webapp widget added")
    }
}

// MARK: - 畫小工具（SBWidgets.drawSBWidget 的 .webApp 走這裡）

extension Face {
    func drawWebAppWidget(_ g: CGContext, _ w: SBWidget, _ r: CGRect, _ a: HomeAppearance, _ preview: Bool, _ now: Double) {
        let mode = a.renderMode(night: false)
        let dark = a.widgetDark
        HPComponents.widgetFrame(g, r, top: (dark ? srgb(0x1C1C1E) : .white).cgColor, bottom: (dark ? srgb(0x1C1C1E) : .white).cgColor,
                                 mode: mode, appearance: a, standalone: preview, radius: Shell.widgetRadius)
        var ink = ACInk(primary: dark ? .white : .black, secondary: (dark ? NSColor.white : .black).withAlphaComponent(0.55), accent: HPTokens.blue, accented: false)
        if mode == .accented { let i = WidgetInk.of(a); ink = ACInk(primary: i.primary, secondary: i.secondary, accent: i.accent, accented: true) }
        let p = SBK.pad
        guard let app = WebAppStore.shared.app(id: w.config["app"] ?? "") else {
            drawLeft(g, L("webapp.widget.gone", "这个 Web App 已删除"), font: HPType.sf(14 * SBK.K, .semibold), x: r.minX + p, y: r.minY + p + 30, color: ink.secondary)
            return
        }
        if let t = app.theme, !ink.accented { ink.accent = srgb(t) }
        // 個人內容：門關著只畫鎖（訪客的快照也一樣）
        if !preview, !WebAppGate.canOpen(app) {
            drawSymbol(g, "lock.fill", in: CGRect(x: r.minX + p, y: r.minY + p, width: 18 * SBK.K, height: 20 * SBK.K), color: ink.secondary)
            let f = HPType.sf(13 * SBK.K, .semibold)
            drawLeft(g, Face.clipped(String(format: L("sb.locked", "%@ · 需要主人"), app.name), f, r.width - 2 * p), font: f, x: r.minX + p, y: r.minY + p + 34 * SBK.K, color: ink.secondary)
            return
        }
        let iconImg = WebAppStore.shared.icon(app.uuid) ?? WebAppIcons.monogram(app)
        if let card = WebAppWidgets.card(app, tag: w.config["tag"] ?? WebAppWidgets.iconTag, now: now) {
            g.saveGState(); g.clip(to: r.insetBy(dx: p * 0.5, dy: p * 0.5))
            let inner = r.insetBy(dx: p, dy: p)
            let s = 20 * SBK.K
            if let iconImg {   // 右上角小圖示：這是哪個 Web App
                let ir = CGRect(x: inner.maxX - s, y: inner.minY, width: s, height: s)
                g.saveGState(); g.addPath(continuousRoundedRect(ir, radius: s * 0.2237)); g.clip(); drawUpright(g, iconImg, in: ir); g.restoreGState()
            }
            let y = ACRender.draw(g, self, card.body, x: inner.minX, y: inner.minY, w: inner.width - s - 6 * SBK.K, ink: ink, image: WebAppWidgets.image)
            if !card.actions.isEmpty {
                let by = min(inner.maxY - 32 * SBK.K, y + 8 * SBK.K)
                ACRender.drawButtons(g, self, card.actions, x: inner.minX, y: by, w: inner.width, ink: ink)
            }
            g.restoreGState()
            HPAX.note(g, r, .button, app.name)
            return
        }
        // 圖示小工具：大圖示＋名字＋網域（寬的 2×1：圖示在左、字在右）
        let nf = HPType.sf(15 * SBK.K, .semibold), hf = HPType.sf(12 * SBK.K, .regular)
        let wide = r.width > r.height * 1.6
        let side = wide ? r.height - 2 * p : min(r.height * 0.42, 72 * SBK.K)
        let ir = CGRect(x: r.minX + p, y: r.minY + p, width: side, height: side)
        if let iconImg { g.saveGState(); g.addPath(continuousRoundedRect(ir, radius: side * 0.2237)); g.clip(); drawUpright(g, iconImg, in: ir); g.restoreGState() }
        let tx = wide ? ir.maxX + 12 * SBK.K : r.minX + p, tw = r.maxX - p - tx
        let ny = wide ? r.midY - 2 * SBK.K : r.maxY - p - 18 * SBK.K, hy = wide ? r.midY + 16 * SBK.K : r.maxY - p
        drawLeft(g, Face.clipped(app.name, nf, tw), font: nf, x: tx, y: ny, color: ink.primary)
        drawLeft(g, Face.clipped(app.host, hf, tw), font: hf, x: tx, y: hy, color: ink.secondary)
        HPAX.note(g, r, .button, app.name)
    }
}

// MARK: - selftest

enum WebAppWidgetSelftest {
    static func run(_ check: (Bool, String) -> Void) {
        let tpl: [String: Any] = ["type": "AdaptiveCard", "version": "1.5", "body": [
            ["type": "TextBlock", "text": "${title}", "size": "Large", "weight": "Bolder"],
            ["type": "TextBlock", "text": "${count} items · ${$root.store.name}", "isSubtle": true],
            ["type": "Container", "$data": "${items}", "items": [["type": "TextBlock", "text": "${$index}. ${name}", "$when": "${!done}"]]],
            ["type": "FactSet", "facts": [["title": "Next", "value": "${items[1].name}"]]],
            ["type": "Image", "url": "file:///etc/passwd"],
            ["type": "Unknown", "text": "x"],
        ], "actions": [["type": "Action.OpenUrl", "title": "Open", "url": "https://a.example/"]]]
        let data: [String: Any] = ["title": "Groceries", "count": 3, "store": ["name": "Corner"],
                                   "items": [["name": "Milk", "done": false], ["name": "Eggs", "done": true], ["name": "Rice", "done": false]]]
        let bound = ACTemplate.bind(tpl, data: data)
        let card = ACCard.parse(bound)
        let texts: [String] = card?.body.flatMap { n -> [String] in
            switch n {
            case .text(let t, _, _, _, _, _, _, _, _): return [t]
            case .container(let items, _): return items.compactMap { if case .text(let t, _, _, _, _, _, _, _, _) = $0 { return t }; return nil }
            default: return []
            }
        } ?? []
        check(texts == ["Groceries", "3 items · Corner", "0. Milk", "2. Rice"], "Web App 小工具：${} 取值、$root、$data 重複、$index、$when（\(texts)）")   // l10n-ignore：selftest 訊息
        let facts = card?.body.first { if case .facts = $0 { return true }; return false }
        check(facts == .facts([ACFact(title: "Next", value: "Eggs")], spacing: "default") && card?.actions == ["Open"],
              "Web App 小工具：FactSet 取陣列、卡片 actions")   // l10n-ignore：selftest 訊息
        check(card?.body.count == 5 && !(card?.body.contains { if case .image = $0 { return true }; return false } ?? true),
              "Web App 小工具：file: 圖片與不認得的元素不畫")   // l10n-ignore：selftest 訊息
        check(ACCard.parse(["type": "Nope"]) == nil && (ACTemplate.interpolate("${n}", .init(data: ["n": 4], root: [:], index: nil)) as? NSNumber)?.intValue == 4,
              "Web App 小工具：不是 AdaptiveCard 不收；整個 ${} 保留型別")   // l10n-ignore：selftest 訊息
        let cols = ACRender.widths([ACColumn(width: "auto", items: [.image(URL(string: "https://x/i.png")!, size: "small", person: false, spacing: "default")]),
                                    ACColumn(width: "stretch", items: []), ACColumn(width: "2", items: [])], 600)
        check(abs(cols[0] - ACRender.imageSide("small")) < 0.5 && abs(cols[2] - 2 * cols[1]) < 0.5 && abs(cols.reduce(0, +) + 16 * SBK.K - 600) < 0.5,
              "Web App 小工具：欄寬 auto／stretch／比例")   // l10n-ignore：selftest 訊息
        let ck = HTTPCookie(properties: [.domain: ".shop.example", .path: "/", .name: "s", .value: "1", .secure: "TRUE"])!
        check(WebAppWidgets.match(ck, URL(string: "https://app.shop.example/w.json")!) && !WebAppWidgets.match(ck, URL(string: "http://app.shop.example/w.json")!)
              && !WebAppWidgets.match(ck, URL(string: "https://evil.example/w.json")!), "Web App 小工具：只帶這個網域的 cookie、secure 只走 https")   // l10n-ignore：selftest 訊息
    }
}

extension SBWidget {
    /// 主畫面上小工具底下的名字、輔助使用的標籤：Web App 的小工具叫 Web App 的名字
    var title: String {
        if kind == .webApp, let a = WebAppStore.shared.app(id: config["app"] ?? "") { return a.name }
        return kind.title
    }
}
