// HPDS v1：Glass——控制層的玻璃（原 Design/HPGlass.swift；舊名 GlassPass 留成 typealias）。規格見 Design/README.md。
//
// 2.0 逼真化第二輪 R13：控制層的系統 Liquid Glass（照 SwiftUI 的 GlassEffectContainer 與 Chan Karunamuni 的講題，見 hv-research/chan-notes.md）。
//
// App 與外殼在 render 時只呼叫 HPGlass.add（形狀＋染色＋玻璃上面的內容）；畫完底下的內容後 flush 一次：
// - 背景＝flush 那一刻的畫面（玻璃不取樣玻璃）；形狀照「變體／染色／按著／融合組」分組，每組用 SystemGlass
//   （macOS 27 自己的 CABackdropLayer glassBackground＋CASDF 零件）算一次，貼回去，再照順序畫每個 content；
// - 變體：Regular 是預設（淺深都是，深色時用 darkAqua 量到的那組）；Clear 只給媒體上的控制（照片、模糊錶面），
//   依底下亮度加 0–35% 壓暗。小元件（短邊 ≤ 200 px）依背後內容自己翻淺／深（有滯後，不閃），大的跟 Theme；
// - 靜止時不融合（容器 spacing 0）；只有同一個 union 名字的形狀在距離場裡融成一塊（變形動畫，例如 ClioTalk 的水滴滴下來）；
// - 外陰影依底下內容調：底下有字（邊緣多）就濃、純淡色就淡，顏色取底下的平均色壓暗；不畫外框；
// - presence 0→1＝materialize：折射帶、模糊、面、亮邊一起從 0 長出來，形狀從 0.96 長到原尺寸；內容才用透明度；
// - 按著（interactive）：按下那一幀放大 1.08、亮邊亮起、從觸碰點亮起一圈往外擴散；放開回彈；
// - 形狀＋背景的雜湊一樣就用上一幀的結果；拿不到系統玻璃退回 LiquidGlass shader，再不行畫半透明的仿製品。

import AppKit

typealias GlassPass = HPGlass

enum HPGlass {
    /// 玻璃的種類（chan-notes G5／G12）：參數表在 SystemGlassParams（macOS 27 量到的 NSGlassEffectView 兩種 style）
    enum Variant {
        /// 預設：淺色與深色畫面都用（深色時自己換成 darkAqua 量到的那組）
        case regular
        /// 只在媒體上（照片、影片、封面、攝影機、模糊錶面）；亮背景上加 0–35% 壓暗
        case clear
        /// 染色玻璃：色進面色矩陣，不是實色；只給主要動作，每個畫面最多兩個
        case tinted(NSColor)
        /// 沒有玻璃（SwiftUI Glass.identity）：「減少透明度」打開時所有形狀都畫成這種——霧面不透明、沒有折射（identityFill）
        case identity
    }
    /// 這種玻璃在淺／深底上的系統參數（flush 合成時用的同一張表）
    static func params(_ v: Variant, darkGlass: Bool) -> SystemGlassParams {
        switch v {
        case .clear: return SystemGlassParams.clearControl
        case .identity: return darkGlass ? SystemGlassParams.regularDark : SystemGlassParams.regular
        case .regular: return darkGlass ? SystemGlassParams.regularDark : SystemGlassParams.regular
        case .tinted(let c):
            var p = darkGlass ? SystemGlassParams.regularDark : SystemGlassParams.regular
            applyTint(&p, c, darkGlass: darkGlass)
            return p
        }
    }
    /// 染色玻璃：色進面色矩陣（不是實色），亮度跟著背景走
    static func applyTint(_ p: inout SystemGlassParams, _ c: NSColor, darkGlass: Bool) {
        guard let t = c.usingColorSpace(.sRGB) else { return }
        p.tint = t.withAlphaComponent(min(t.alphaComponent, darkGlass ? 0.72 : 0.82)).cgColor
        p.black = max(p.black, 0.25)
    }
    /// 每個畫面最多幾個染色形狀
    static let maxTintedPerScreen = 2
    /// 小元件（短邊 ≤ 這個）依背後內容自己翻淺／深；比它大的跟 HPTokens.dark
    static let adaptiveMaxSide: CGFloat = 200
    /// union 融合距離（只在變形動畫中；靜止時 0）
    nonisolated(unsafe) static var unionMerge: CGFloat = 14
    /// 2.0 glass：靜止時的亮邊（系統 @2 CASDFKeyFillHighlightEffect 的 keyColor 不透明度）。macOS 的 NSGlassEffectView 靜止是 0、
    /// 互動才亮；iOS／HomeView 官方圖（recipe-overview 的膠囊、✕）靜止就有一道吃到背景色的亮緣，所以產品用這個值、校準台用 0
    nonisolated(unsafe) static var restRim: CGFloat = CGFloat(Double(ProcessInfo.processInfo.environment["HOMEPLAY_GLASS_RIM"] ?? "") ?? 1.0)

    /// 2.0 glass（第二次校準）：HomeView 的畫面用 iOS 家族的玻璃（Design/HPGlassIOS.swift：更透明、靜止亮緣吃背景色、濾鏡自己畫外陰影）；
    /// 2.0 iosglass：畫面一律 iOS；.macOS 只剩校準台對 NSGlassEffectView 時暫時切過去（參考／基準，不在任何畫面的路徑上）
    nonisolated(unsafe) static var platform: HPGlassPlatform = .iOS
    /// iOS 的外陰影由系統濾鏡畫（緣外那一圈跟玻璃一起貼回去），我們自己的自適應外陰影就不畫
    static var systemShadow: Bool { platform == .iOS && NativeGlass.shared.available }
    /// 貼回去時要外擴多少（畫布 px）：macOS 是緣外約 1 px 的暗邊；iOS 是濾鏡的外陰影（CASDFOutputEffect maximum）
    static func blitOutset(_ shapes: [NativeGlass.Shape], clear: Bool, dark: Bool) -> CGFloat {
        guard platform == .iOS else { return nativeOutset }
        let side = Double((shapes.map { min($0.rect.width, $0.rect.height) }.max() ?? 0) / SystemGlassParams.ptToCanvas)
        return CGFloat(IOSGlass.outputMaximum(side: side, clear: clear, dark: dark)) * SystemGlassParams.ptToCanvas
    }

    /// 輔助使用設定（Design/HPAccessibility.swift；HOMEPLAY_REDUCE_TRANSPARENCY／HOMEPLAY_INCREASE_CONTRAST＝1 強制打開）
    static var reduceTransparency: Bool { HPAccessibility.reduceTransparency }
    static var increaseContrast: Bool { HPAccessibility.increaseContrast }
    /// 減少透明度時的霧面不透明（HIG：systemGray6 #F2F2F7／#1C1C1E，95%）
    static func identityFill(dark: Bool) -> NSColor { dark ? NSColor(srgbRed: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 0.95) : NSColor(srgbRed: 242 / 255, green: 242 / 255, blue: 247 / 255, alpha: 0.95) }
    /// 設定改了：丟掉玻璃快取
    static func discardCache() { cache.removeAll(); order.removeAll() }

    /// 開關／滑桿的旋鈕：操作中（moving 0…1）變成玻璃、略放大（Adopting Liquid Glass：knob transforms into Liquid Glass during interaction）；
    /// 靜止時回 false，呼叫端照舊畫白色旋鈕（HPComponents.toggle 用它；畫面要在內容之後 flush）
    @discardableResult
    static func addKnob(_ knob: CGRect, moving: CGFloat, content: @escaping (CGContext) -> Void = { _ in }) -> Bool {
        guard moving > 0.02, !HPMotion.reduceMotion else { return false }
        let s = 1 + 0.35 * min(1, moving)
        let r = CGRect(x: knob.midX - knob.width * s / 2, y: knob.midY - knob.height * s / 2, width: knob.width * s, height: knob.height * s)
        addCapsule(r, interactive: false, presence: min(1, moving * 1.5), content: content)
        return true
    }
    /// 2.0 glass：校準台用——只畫材質本身（不翻淺深、不壓暗 Clear、不畫外陰影），跟 NSGlassEffectView 逐像素比
    nonisolated(unsafe) static var materialOnly = false

    struct Item {
        let path: CGPath
        let tint: NSColor?
        let interactive: Bool
        let union: String?
        let presence: CGFloat
        var container: String? = nil
        let content: (CGContext) -> Void
    }
    nonisolated(unsafe) private static var items: [Item] = []
    nonisolated(unsafe) private static var currentContainer: String?
    /// 2.0 glass（第二次校準）：GlassEffectContainer——body 裡加的形狀算同一個容器（iOS 共用一個 backdrop：
    /// 內折射跟最小的形狀、其餘跟最大的走，食譜封面的 ✕＋兩顆膠囊就是這樣）。不融合；融合照舊用 union
    static func container(_ name: String, _ body: () -> Void) {
        let old = currentContainer; currentContainer = name; body(); currentContainer = old
    }

    /// 這一幀要上玻璃的控制：形狀（1024 畫布座標的 CGPath）、染色（nil＝清玻璃）、玻璃上面的內容（符號、字）
    static func add(_ path: CGPath, tint: NSColor? = nil, interactive: Bool = false, content: @escaping (CGContext) -> Void) {
        add(path, tint: tint, interactive: interactive, union: nil, presence: 1, content: content)
    }
    /// union：同名的形狀融成一塊（只在變形中用）；presence：materialize 進度 0…1
    static func add(_ path: CGPath, tint: NSColor? = nil, interactive: Bool = false, union: String?, presence: CGFloat = 1,
                    content: @escaping (CGContext) -> Void) {
        guard presence > 0.001 else { return }
        items.append(Item(path: path, tint: tint, interactive: interactive, union: union, presence: min(1, presence), container: currentContainer, content: content))
    }
    /// 方便：玻璃膠囊／圓（r 是正方形就是圓）
    static func addCapsule(_ r: CGRect, tint: NSColor? = nil, interactive: Bool = true, union: String? = nil, presence: CGFloat = 1,
                           content: @escaping (CGContext) -> Void = { _ in }) {
        add(CGPath(roundedRect: r, cornerWidth: min(r.width, r.height) / 2, cornerHeight: min(r.width, r.height) / 2, transform: nil),
            tint: tint, interactive: interactive, union: union, presence: presence, content: content)
    }
    /// 2.0 iosglass：馬上畫這幾塊（不等這一幀的 flush；呼叫端接著在上面畫內容）。還沒畫的先收起來、畫完放回去
    static func drawNow(_ g: CGContext, face: Face, _ paths: [CGPath], clear: Bool, backdrop: CGImage? = nil, container name: String? = nil) {
        let pending = items; items.removeAll()
        let body = { for p in paths { add(p) { _ in } } }
        if let name { container(name, body) } else { body() }
        flush(g, face: face, clear: clear, backdrop: backdrop)
        items = pending
    }
    /// 丟掉還沒畫的（換畫面、這一幀放棄）
    static func discard() { items.removeAll() }

    /// content 畫的時候：這塊玻璃是淺版（字與符號用深色）還是深版（用白）。content 裡用 HPGlass.ink
    nonisolated(unsafe) static var ink: NSColor = .black
    nonisolated(unsafe) static var inkIsLight = false

    // MARK: 按下

    /// 按下的位置（1024 畫布）與按壓的彈簧（0 放開 … 1 按著）
    nonisolated(unsafe) static var press: (point: CGPoint, anim: MotionValue)?
    /// 影片 v1 01:05.00 FaceTime 鈕按下 ≈ 0.1 s 放大變亮；Apple 的 interactiveSpring＝(0.86, 0.15)
    static func pressDown(_ p: CGPoint, now: Double = CACurrentMediaTime()) {
        // 同一顆再按：從當下的值接著走；換一顆：從 0 開始
        if var cur = press, hypot(cur.point.x - p.x, cur.point.y - p.y) < 4 { cur.anim.retarget(1, now: now); press = cur; return }
        press = (p, MotionValue("press", spring: .interactive, from: 0, to: 1, now: now))
    }
    static func pressUp(now: Double = CACurrentMediaTime()) {
        guard var p = press else { return }
        p.anim.retarget(0, now: now, spring: .snappy); press = p   // 放開回彈（有一點點過衝）
    }
    /// 拖出取消（iOS 的 touch 拖出形狀）：指標離開按住的形狀→按壓收掉。回傳有沒有改變（外殼拿去標記重繪）。
    /// at：拖回形狀內要再亮（放開也會作用）的那顆的錨點；沒給就只收不回。
    /// 沒有 hover：HomeView 是觸控裝置，官方畫面沒有滑鼠懸停的狀態，不自己發明
    static func pressOver(_ inside: Bool, at anchor: CGPoint? = nil, now: Double = CACurrentMediaTime()) -> Bool {
        if var p = press {
            let to: Double = inside ? 1 : 0
            guard p.anim.to != to else { return false }
            p.anim.retarget(to, now: now, spring: inside ? .interactive : .snappy); press = p
            return true
        }
        guard inside, let anchor else { return false }
        pressDown(anchor, now: now)   // 已經收掉又拖回來：重新按（錨點同一顆）
        return true
    }
    /// 這個形狀按著多少（0…1.x）
    static func pressAmount(_ path: CGPath, now: Double) -> CGFloat {
        guard let p = press, path.boundingBoxOfPath.insetBy(dx: -8, dy: -8).contains(p.point) else { return 0 }
        return max(0, min(1.2, p.anim.value(now)))
    }
    /// 按壓動畫還在動（外殼每幀問）
    static func animating(_ now: Double) -> Bool {
        guard let p = press else { return false }
        if p.anim.to == 0, p.anim.done(now) { press = nil; return true }
        return !p.anim.done(now)
    }
    static let pressScale: CGFloat = 0.08
    /// 2.0 glass：materialize 時形狀的大小。校準台拍到的 SwiftUI 玻璃出現（GlassEffectContainer 裡插入）：形狀從約 1.05 倍收到 1，
    /// 收得比光學量長出來快（光學 16% 時大 4%、65% 時只大 0.5%）——不是從小長大
    static func materializeScale(_ presence: CGFloat) -> CGFloat { 1 + 0.05 * (1 - presence) * (1 - presence) }

    // MARK: 合成

    nonisolated(unsafe) private static var cache: [String: (image: CGImage, rect: CGRect, mask: CGImage?, outset: CGFloat)] = [:]
    /// 系統玻璃的輸出比形狀大一點（CASDFOutputEffect maximum 1.5：緣外約 1 px 的暗邊）：貼回去時裁切外擴這麼多（畫布 px）
    static var nativeOutset: CGFloat { 0.75 * SystemGlassParams.ptToCanvas }
    nonisolated(unsafe) private static var order: [String] = []
    /// 小元件淺／深的滯後狀態（照形狀位置記）
    nonisolated(unsafe) private static var flip: [String: Bool] = [:]
    nonisolated(unsafe) static var stats = (hits: 0, misses: 0, fallbacks: 0)

    /// 把收集到的形狀上玻璃、畫內容。clear：true＝媒體上的 Clear（照片、模糊錶面）；false/nil＝Regular。
    /// backdrop：給了就用它當背景（控制中心：霧化的底圖，磚一起位移），否則拍當下這一幀
    static func flush(_ g: CGContext, face: Face, clear: Bool? = nil, backdrop given: CGImage? = nil, now: Double = CACurrentMediaTime()) {
        let list = items
        items.removeAll()
        guard !list.isEmpty else { return }
        let sc = face.renderPixelScale
        let useClear = clear ?? false
        let backdrop = given ?? g.makeImage()
        let probe = backdrop.map { BackdropProbe($0) }
        // 每個形狀：按著放大、materialize 縮放、淺深
        struct Shaped { let item: Item; let path: CGPath; let press: CGFloat; let darkGlass: Bool; let stats: (lum: CGFloat, edge: CGFloat, avg: NSColor); var live = false }
        var shaped: [Shaped] = list.map { it in
            // 2.0 live glass：容器、融合組、互動的形狀交給 LiveGlass 的常駐系統樹（按壓照舊用我們的放大與光）
            let live = LiveGlass.claims(container: it.container, union: it.union, interactive: it.interactive, presence: it.presence, path: it.path)
            let k = it.interactive ? pressAmount(it.path, now: now) : 0
            let b = it.path.boundingBoxOfPath
            let s = (1 + pressScale * k) * materializeScale(it.presence)
            var t = CGAffineTransform(translationX: b.midX, y: b.midY).scaledBy(x: s, y: s).translatedBy(x: -b.midX, y: -b.midY)
            let p = abs(s - 1) < 0.0005 ? it.path : (it.path.copy(using: &t) ?? it.path)
            let st: (lum: CGFloat, edge: CGFloat, avg: NSColor) = probe?.stats(b) ?? (HPTokens.dark ? 0.1 : 0.9, 0, NSColor.gray)
            var dark = HPTokens.dark
            if !materialOnly, min(b.width, b.height) <= adaptiveMaxSide {   // 小元件：依背後內容翻（> 0.6 淺、< 0.4 深，中間維持上次）
                let fk = "\(Int(b.midX / 8)),\(Int(b.midY / 8))"
                let prev = flip[fk] ?? (st.lum < 0.5)
                dark = st.lum < 0.4 ? true : (st.lum > 0.6 ? false : prev)
                flip[fk] = dark
                if flip.count > 200 { flip.removeAll() }
            }
            if useClear, !materialOnly { dark = true }   // Clear 上的符號一律白（媒體上、壓暗後）
            return Shaped(item: it, path: p, press: k, darkGlass: dark, stats: st, live: live)
        }
        // 外陰影（自適應）：底下有字（邊緣多）就濃、純色就淡；顏色＝底下平均色壓暗。玻璃再蓋上去
        for sh in shaped where !materialOnly && !systemShadow {
            let a = (0.10 + 0.20 * min(1, sh.stats.edge * 6)) * sh.item.presence
            let col = (sh.stats.avg.blended(withFraction: 0.75, of: .black) ?? .black).withAlphaComponent(a)
            let big = min(sh.path.boundingBoxOfPath.width, sh.path.boundingBoxOfPath.height) > 200
            g.saveGState()
            // 只畫在形狀外面（裡面要留給玻璃取樣乾淨的背景）
            g.addRect(CGRect(x: -200, y: -200, width: 1424, height: 1424)); g.addPath(sh.path); g.clip(using: .evenOdd)
            g.setShadow(offset: CGSize(width: 0, height: big ? -10 : -5), blur: big ? 40 : 22, color: col.cgColor)
            g.addPath(sh.path); g.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor); g.fillPath()
            g.restoreGState()
        }
        // Clear：亮的背景上先壓暗（0–35%），符號才讀得到
        if useClear, !materialOnly {
            for sh in shaped where min(sh.path.boundingBoxOfPath.width, sh.path.boundingBoxOfPath.height) <= 200 {   // 只給小控制：面板不壓暗整面
                let dim = max(0, min(1, (sh.stats.lum - 0.35) / 0.4)) * 0.35 * sh.item.presence
                guard dim > 0.01 else { continue }
                g.saveGState(); g.addPath(sh.path); g.setFillColor(NSColor(white: 0, alpha: dim).cgColor); g.fillPath(); g.restoreGState()
            }
        }
        let dimmedBackdrop = useClear ? g.makeImage() ?? backdrop : backdrop
        let identity = reduceTransparency && !materialOnly
        var pending: [Blit] = []
        if shaped.contains(where: \.live) {
            let r = liveBlits(shaped.filter(\.live).map { ($0.item, $0.path, $0.darkGlass, $0.press > 0.001) }, clear: useClear, backdrop: dimmedBackdrop, given: given, sc: sc)
            pending = r.blits
            for i in shaped.indices where shaped[i].live && r.failed.contains(liveScene(shaped[i].item, dark: shaped[i].darkGlass, pressed: shaped[i].press > 0.001)) { shaped[i].live = false }   // 退回 NativeGlass
        }
        // 分組
        var groups: [(key: String, tint: NSColor?, press: CGFloat, dark: Bool, presence: CGFloat, union: Bool, container: Bool, paths: [CGPath])] = []
        for sh in shaped where !sh.live {
            let tk = sh.item.tint.flatMap { $0.usingColorSpace(.sRGB) }.map { String(format: "%.3f,%.3f,%.3f,%.2f", $0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent) } ?? "clear"
            let key = "\(tk)|\(sh.press > 0.001 ? String(format: "p%.2f", sh.press) : "-")|\(sh.darkGlass)|\(String(format: "%.2f", sh.item.presence))|\(sh.item.union ?? "")|\(sh.item.container ?? "")"
            if let i = groups.firstIndex(where: { $0.key == key }) { groups[i].paths.append(sh.path) }
            else { groups.append((key, sh.item.tint, sh.press, sh.darkGlass, sh.item.presence, sh.item.union != nil, sh.item.container != nil, [sh.path])) }
        }
        for grp in groups where !identity {
            let path = CGMutablePath()
            for p in grp.paths { path.addPath(p) }
            let merge: CGFloat = grp.union && grp.paths.count > 1 && !HPMotion.reduceMotion ? unionMerge : 0
            var params = useClear ? SystemGlassParams.clearControl : (grp.dark ? SystemGlassParams.regularDark : SystemGlassParams.regular)
            if let t = grp.tint { applyTint(&params, t, darkGlass: grp.dark) }
            if grp.press > 0 {   // 按著：系統的 @2 亮邊亮起（平常 0）、面更亮
                params.rim = min(1, grp.press)
                params.white = min(1.2, params.white + 0.05 * grp.press)
            }
            if grp.presence < 0.999 {   // materialize：折射、模糊、面、高光一起長出來
                let k = grp.presence
                params.refractionHeight *= k; params.blurRadius *= k; params.fill *= k; params.highlight *= k
                params.black *= k; params.white = 1 + (params.white - 1) * k
            }
            let native = NativeGlass.Request(shapes: grp.paths.map(nativeShape), clear: useClear, dark: grp.dark, tint: grp.tint,
                                             merge: merge, press: materialOnly && platform == .macOS ? min(1, grp.press) : max(restRim, min(1, grp.press)),
                                             presence: grp.presence, scale: sc, platform: platform, container: grp.container && grp.paths.count > 1)
            if let b = drawGroup(g, face: face, path: path, merge: merge, params: params, key: grp.key, backdrop: dimmedBackdrop, givenBackdrop: given, sc: sc,
                                 presence: grp.presence, native: native) { pending.append(b) }
        }
        // 先貼每組緣外那一圈（不蓋到任何一塊玻璃），再貼形狀裡面：iOS 的外陰影比較寬，鄰組的圈不會蓋掉別組的玻璃
        let allShapes = CGMutablePath()
        for sh in shaped { allShapes.addPath(sh.path) }
        for b in pending where b.outset > 0 { blitRing(g, face: face, b, excluding: allShapes) }
        for b in pending { blit(g, face: face, b.image, b.rect, mask: b.mask, path: b.path) }
        // 2.0 glass（P01）：輔助使用——「減少透明度」不畫玻璃，改霧面不透明（.identity，沒有折射；染色的用自己的色 95%）；
        // 「增加對比」加 1.5 px 的 label 色描邊（只畫在形狀裡面那一半，不往外長）
        if !materialOnly, identity || increaseContrast {
            for sh in shaped {
                g.saveGState()
                if identity {
                    let base = sh.item.tint.map { $0.withAlphaComponent(0.95) } ?? identityFill(dark: sh.darkGlass)
                    g.addPath(sh.path); g.setFillColor(base.withAlphaComponent(base.alphaComponent * sh.item.presence).cgColor); g.fillPath()
                }
                if increaseContrast {
                    let label: NSColor = sh.darkGlass ? .white : .black
                    g.addPath(sh.path); g.clip()
                    g.addPath(sh.path); g.setLineWidth(3); g.setStrokeColor(label.withAlphaComponent(sh.item.presence).cgColor); g.strokePath()
                }
                g.restoreGState()
            }
        }
        // 按下的光：從觸碰點亮起、往外擴散到整塊
        if let p = press {
            for sh in shaped where sh.press > 0.001 {
                let b = sh.path.boundingBoxOfPath
                let radius = hypot(b.width, b.height) * (0.25 + 0.75 * min(1, sh.press))
                g.saveGState(); g.addPath(sh.path); g.clip()
                let cs = CGColorSpace(name: CGColorSpace.sRGB)
                let a = (sh.darkGlass ? 0.22 : 0.35) * min(1, sh.press)
                if let grad = CGGradient(colorsSpace: cs, colors: [NSColor(white: 1, alpha: a).cgColor, NSColor(white: 1, alpha: a * 0.35).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                                         locations: [0, 0.55, 1]) {
                    g.drawRadialGradient(grad, startCenter: p.point, startRadius: 0, endCenter: p.point, endRadius: radius, options: [])
                }
                g.restoreGState()
            }
        }
        for sh in shaped {
            g.saveGState()
            let b = sh.item.path.boundingBoxOfPath, s = (1 + pressScale * sh.press) * materializeScale(sh.item.presence)
            if abs(s - 1) > 0.0005 { g.translateBy(x: b.midX, y: b.midY); g.scaleBy(x: s, y: s); g.translateBy(x: -b.midX, y: -b.midY) }
            if sh.item.presence < 0.999 { g.setAlpha(max(0, (sh.item.presence - 0.3) / 0.7)) }
            inkIsLight = sh.darkGlass
            ink = sh.darkGlass ? .white : .black
            sh.item.content(g)
            g.restoreGState()
        }
        ink = HPTokens.label; inkIsLight = HPTokens.dark
    }

    /// 第五輪：大面板（主畫面那塊玻璃）的厚度——flush 之後疊在系統玻璃上：邊上一道 2 px 亮線、往內約 24 px 的內光
    /// （官方 home-screen-erica：邊上 (216,174,165) 對面板內 (152,98,88)，約 24 px 漸回；沒有亮邊的面板看起來像一張灰卡片）
    static func panelRim(_ g: CGContext, _ path: CGPath) {
        let H = HPTokens.Home.self
        g.saveGState()
        g.addPath(path); g.clip()
        // 內光：形狀外面整片填色、只讓影子落進形狀裡
        g.setShadow(offset: .zero, blur: H.panelGlowBlur, color: NSColor(white: 1, alpha: H.panelGlowAlpha).cgColor)
        g.addRect(CGRect(x: -400, y: -400, width: 1824, height: 1824)); g.addPath(path)
        g.setFillColor(NSColor(white: 1, alpha: 1).cgColor); g.fillPath(using: .evenOdd)
        g.setShadow(offset: .zero, blur: 0, color: nil)
        // 亮線（只有裡面那一半看得到，所以線寬給兩倍）
        g.addPath(path); g.setLineWidth(H.panelRimLine * 2)
        g.setStrokeColor(NSColor(white: 1, alpha: H.panelRimAlpha).cgColor); g.strokePath()
        g.restoreGState()
    }

    /// 任兩個形狀的外框距離小於 24 px（selftest 與 union 的提示用）
    static func needsMerge(_ boxes: [CGRect]) -> Bool {
        guard boxes.count > 1 else { return false }
        for i in 0..<boxes.count {
            for j in (i + 1)..<boxes.count {
                let a = boxes[i], b = boxes[j]
                let dx = max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX)), dy = max(0, max(a.minY, b.minY) - min(a.maxY, b.maxY))
                if hypot(dx, dy) < 24 { return true }
            }
        }
        return false
    }

    /// 2.0 glass：CGPath → 系統玻璃的形狀（圓角矩形、膠囊、圓走 bounds 模式；其他形狀帶 path，改用距離場圖）
    static func nativeShape(_ p: CGPath) -> NativeGlass.Shape {
        if let r = NativeGlass.roundedRect(of: p) { return NativeGlass.Shape(rect: r.rect, radius: r.radius, continuous: r.continuous) }
        return NativeGlass.Shape(rect: p.boundingBoxOfPath, radius: 0, continuous: true, path: p)
    }

    /// 2.0 live glass：這個形狀屬於哪一棵常駐樹——容器或融合組（同色、同淺深）；都沒有的互動形狀：同一次 flush 的放一棵
    /// （一幀裡第幾次 flush：主畫面一幀會 flush 好幾次，各自一棵才不會每次互相搬來搬去）
    nonisolated(unsafe) private static var flushOrdinal = (render: -1, n: 0)
    /// 按著的那顆自己一棵（跟今天的分組一樣）：按壓每幀只重畫它那一小塊，同容器的其他形狀用快取
    private static func liveScene(_ it: Item, dark: Bool, pressed: Bool) -> String {
        let tk = it.tint.flatMap { $0.usingColorSpace(.sRGB) }.map { String(format: "%.3f,%.3f,%.3f,%.2f", $0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent) } ?? "-"
        let group = it.container.map { "c:\($0)" } ?? it.union.map { "u:\($0)" } ?? "f:\(flushOrdinal.n)"
        return "\(group)|\(tk)|\(dark)\(pressed ? "|p" : "")"
    }
    /// 每棵樹一次 LiveGlass.render；貼回去跟 NativeGlass 的結果一樣（緣外一圈＋形狀裡面，融合組用 smooth union 遮罩）。回傳拿不到的樹（那幾個形狀退回 NativeGlass）
    private static func liveBlits(_ list: [(item: Item, path: CGPath, dark: Bool, pressed: Bool)], clear: Bool, backdrop: CGImage?, given: CGImage?, sc: CGFloat) -> (blits: [Blit], failed: Set<String>) {
        if flushOrdinal.render != Face.renderCount { flushOrdinal = (Face.renderCount, 0) } else { flushOrdinal.n += 1 }
        var names: [String] = []
        for e in list { let n = liveScene(e.item, dark: e.dark, pressed: e.pressed); if !names.contains(n) { names.append(n) } }
        guard let backdrop else { return ([], Set(names)) }
        let probe = given == nil ? BackdropProbe(backdrop) : nil
        var out: [Blit] = [], failed = Set<String>()
        for name in names {
            let mine = list.filter { liveScene($0.item, dark: $0.dark, pressed: $0.pressed) == name }
            let shapes = mine.map { nativeShape($0.path) }
            let dark = mine[0].dark, tint = mine[0].item.tint
            let merge: CGFloat = mine.contains { $0.item.union != nil } && mine.count > 1 && !HPMotion.reduceMotion ? unionMerge : 0
            let outset = blitOutset(shapes, clear: clear, dark: dark)
            var ink = shapes[0].rect
            for sh in shapes.dropFirst() { ink = ink.union(sh.rect) }
            let pad = max(outset, nativeOutset) + 4
            let bkey = given.map { "img\(ObjectIdentifier($0).hashValue)" } ?? probe?.hash(ink.insetBy(dx: -pad, dy: -pad)) ?? ""
            let key = shapes.map(\.key).joined(separator: ";") + "|\(bkey)|\(clear)|\(sc)"
            guard let r = LiveGlass.shared.render(scene: name, shapes: shapes, clear: clear, dark: dark, tint: tint, merge: merge,
                                                  backdrop: backdrop, scale: sc, pad: pad, key: key) else { failed.insert(name); continue }
            let path = CGMutablePath()
            for e in mine { path.addPath(e.path) }
            let mask = merge > 0 ? NativeGlass.unionMask(shapes, rect: r.rect, scale: sc, smooth: merge, outset: nativeOutset) : nil
            out.append(Blit(image: r.image, rect: r.rect, mask: mask, path: path, outset: outset))
        }
        return (out, failed)
    }

    /// 一組玻璃的結果，等全部算完再貼（先貼緣外的圈、再貼裡面）
    struct Blit { let image: CGImage; let rect: CGRect; let mask: CGImage?; let path: CGPath; let outset: CGFloat }

    private static func drawGroup(_ g: CGContext, face: Face, path: CGPath, merge: CGFloat, params: SystemGlassParams, key: String,
                                  backdrop: CGImage?, givenBackdrop: CGImage?, sc: CGFloat, presence: CGFloat, native: NativeGlass.Request? = nil) -> Blit? {
        let ink = path.boundingBoxOfPath
        guard ink.width > 1, ink.height > 1 else { return nil }
        if let backdrop {
            let bkey = givenBackdrop.map { "img\(ObjectIdentifier($0).hashValue)" } ?? BackdropProbe(backdrop).hash(ink)
            let shapes = ink.debugDescription + "#\(pathHash(path))"
            let full = "\(key)|\(shapes)|\(bkey)|\(params.black)\(params.white)\(params.blurRadius)\(params.tint != nil)|\(Int(sc * 100))|\(merge)|\(platform)"
            if let c = cache[full] {
                stats.hits += 1
                return Blit(image: c.image, rect: c.rect, mask: c.mask, path: path, outset: c.outset)
            }
            // 2.0 glass：先用真的 NSGlassEffectView 層樹（SystemGlassNative.swift）；融合組的遮罩是同一個 smooth union（k＝spacing）
            if let native, let out = NativeGlass.shared.render(native, backdrop: backdrop) {
                stats.misses += 1
                let m: CGImage? = merge > 0 && native.shapes.count > 1
                    ? (native.shapes.allSatisfy { $0.path == nil } ? NativeGlass.unionMask(native.shapes, rect: out.rect, scale: sc, smooth: merge, outset: nativeOutset)
                                                                     : SystemGlass.shared.mergeMask(path: path, rect: out.rect, scale: sc, merge: merge)) : nil
                let outset = blitOutset(native.shapes, clear: native.clear, dark: native.dark)
                order.append(full)
                if order.count > 24 { cache[order.removeFirst()] = nil }
                cache[full] = (out.image, out.rect, m, outset)
                return Blit(image: out.image, rect: out.rect, mask: m, path: path, outset: outset)
            }
            if let out = SystemGlass.shared.renderContainer(path: path, key: "glasspass|\(shapes)|\(merge)", scale: sc, backdrop: backdrop,
                                                            params: params, merge: merge) {
                stats.misses += 1
                let m: CGImage? = merge > 0 ? out.mask : nil
                cache[full] = (out.image, out.rect, m, 0)
                order.append(full)
                if order.count > 24 { cache[order.removeFirst()] = nil }
                return Blit(image: out.image, rect: out.rect, mask: m, path: path, outset: 0)
            }
            // 系統玻璃拿不到：自己的光學 shader
            if let r = LiquidGlass.shared.render(path: path, key: nil, scale: sc, backdrop: backdrop, frosted: nil, params: .portrait) {
                stats.fallbacks += 1
                g.saveGState(); g.setAlpha(presence); face.drawUpright(g, r.image, in: r.rect); g.restoreGState()
                return nil
            }
        }
        // 最後：半透明的仿製品（不加外框）
        stats.fallbacks += 1
        let light = params.fill > 0.05
        g.saveGState(); g.addPath(path)
        g.setFillColor((params.tint.map { NSColor(cgColor: $0) ?? .white } ?? NSColor(white: light ? 1 : 0.3, alpha: (light ? 0.75 : 0.55) * presence)).cgColor)
        g.fillPath(); g.restoreGState()
        return nil
    }

    /// 緣外那一圈（macOS 的暗邊、iOS 的外陰影）：結果是不透明的合成，同一張圖貼在形狀外 outset 以內，避開所有玻璃形狀
    private static func blitRing(_ g: CGContext, face: Face, _ b: Blit, excluding all: CGPath) {
        g.saveGState()
        g.addRect(CGRect(x: -400, y: -400, width: 1824, height: 1824)); g.addPath(all); g.clip(using: .evenOdd)
        g.addPath(b.path.copy(strokingWithWidth: b.outset * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)); g.clip()
        face.drawUpright(g, b.image, in: b.rect)
        g.restoreGState()
    }

    /// 玻璃結果貼回去：裁成形狀（融合時用遮罩，橋也在裡面）
    private static func blit(_ g: CGContext, face: Face, _ img: CGImage, _ rect: CGRect, mask: CGImage?, path: CGPath) {
        g.saveGState()
        if let mask {
            g.translateBy(x: 0, y: rect.minY + rect.maxY); g.scaleBy(x: 1, y: -1)
            g.clip(to: rect, mask: mask)
            g.translateBy(x: 0, y: rect.minY + rect.maxY); g.scaleBy(x: 1, y: -1)
        } else {
            g.addPath(path); g.clip()
        }
        face.drawUpright(g, img, in: rect)
        g.restoreGState()
    }

    private static func pathHash(_ p: CGPath) -> Int {
        var h = Hasher()
        p.applyWithBlock { e in
            h.combine(e.pointee.type.rawValue)
            let n: Int
            switch e.pointee.type { case .moveToPoint, .addLineToPoint: n = 1; case .addQuadCurveToPoint: n = 2; case .addCurveToPoint: n = 3; default: n = 0 }
            for i in 0..<n { h.combine(Int(e.pointee.points[i].x * 4)); h.combine(Int(e.pointee.points[i].y * 4)) }
        }
        return h.finalize()
    }
}

/// 背景在某一塊的樣子：縮成 12×12 取平均亮度、邊緣量（相鄰像素亮度差）、平均色與雜湊
struct BackdropProbe {
    let img: CGImage
    init(_ img: CGImage) { self.img = img }

    private func sample(_ r: CGRect) -> [UInt8]? {
        let k = CGFloat(img.width) / 1024
        let crop = r.insetBy(dx: -24, dy: -24).intersection(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        guard !crop.isNull, let sub = img.cropping(to: CGRect(x: crop.minX * k, y: crop.minY * k, width: crop.width * k, height: crop.height * k).integral)
        else { return nil }
        var px = [UInt8](repeating: 0, count: 12 * 12 * 4)
        guard let ctx = CGContext(data: &px, width: 12, height: 12, bitsPerComponent: 8, bytesPerRow: 48,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(sub, in: CGRect(x: 0, y: 0, width: 12, height: 12))
        return px
    }
    func stats(_ r: CGRect) -> (lum: CGFloat, edge: CGFloat, avg: NSColor) {
        guard let px = sample(r) else { return (0.5, 0, .gray) }
        var lums = [CGFloat](repeating: 0, count: 144), sr = 0.0, sg = 0.0, sb = 0.0
        for i in 0..<144 {
            let r = Double(px[i * 4]), g = Double(px[i * 4 + 1]), b = Double(px[i * 4 + 2])
            sr += r; sg += g; sb += b
            lums[i] = CGFloat((0.2126 * r + 0.7152 * g + 0.0722 * b) / 255)
        }
        var edge: CGFloat = 0
        for y in 0..<12 { for x in 0..<11 { edge += abs(lums[y * 12 + x + 1] - lums[y * 12 + x]) } }
        let n = 144.0 * 255
        return (lums.reduce(0, +) / 144, edge / 132, NSColor(srgbRed: sr / n, green: sg / n, blue: sb / n, alpha: 1))
    }
    func hash(_ r: CGRect) -> String {
        guard let px = sample(r) else { return "?" }
        var h: UInt64 = 1469598103934665603
        for b in px { h = (h ^ UInt64(b >> 2)) &* 1099511628211 }   // 低兩位丟掉：雜訊不算變化
        return String(h, radix: 36)
    }
}

// 2.0 r2：GlassPass 的暫代版（Design/HPGlass.swift）要知道當下畫在哪張 context；外殼包的正式版會延到幀尾一起畫，這個變數就沒人讀。
/// RealUI 的玻璃零件都用 with(g) 包著 HPGlass.add
enum GlassPassShim {
    nonisolated(unsafe) static var context: CGContext?
    static func with(_ g: CGContext, _ body: () -> Void) {
        let old = context; context = g; body(); context = old
    }
    /// 底下這塊的平均亮度（0…1）；拿不到畫面就 nil
    static func luminance(_ g: CGContext, _ r: CGRect) -> Double? {
        guard let img = g.makeImage() else { return nil }
        let sx = CGFloat(img.width) / 1024, sy = CGFloat(img.height) / 1024
        // 位圖原點在左上（makeImage 的畫布已翻轉）；CGImage 的裁切座標也是左上原點
        let crop = CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy).integral
        guard let part = img.cropping(to: crop), let c = Shell.averageColor(part)?.usingColorSpace(.sRGB) else { return nil }
        return Double(0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent)
    }
    static func draw(_ g: CGContext, _ path: CGPath, tint: NSColor?) {
        let box = path.boundingBox
        // chan-notes G8：小玻璃依背後內容各自翻淺／深（不是看全域主題）；不加外框（S7）
        let dark = box.width <= 240 && box.height <= 240 ? (luminance(g, box).map { $0 < 0.5 } ?? HPTokens.dark) : HPTokens.dark
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: 4), blur: 18, color: NSColor(white: 0, alpha: dark ? 0.35 : 0.12).cgColor)
        let fill = tint.map { $0.withAlphaComponent(0.82 * $0.alphaComponent) } ?? NSColor(white: dark ? 0.5 : 1, alpha: dark ? 0.22 : 0.72)
        g.addPath(path); g.setFillColor(fill.cgColor); g.fillPath()
        g.restoreGState()
        g.saveGState()
        g.addPath(path); g.setLineWidth(2.5); g.replacePathWithStrokedPath(); g.clip()
        let rim = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                             colors: [NSColor(white: 1, alpha: 0.5).cgColor, NSColor(white: 1, alpha: 0.06).cgColor, NSColor(white: 1, alpha: 0.22).cgColor] as CFArray,
                             locations: [0, 0.5, 1])!
        g.drawLinearGradient(rim, start: CGPoint(x: box.minX, y: box.minY), end: CGPoint(x: box.maxX, y: box.maxY), options: [])
        g.restoreGState()
    }
}
