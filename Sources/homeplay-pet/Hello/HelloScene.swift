// 2.0 hello：開機的「hello」——暖色網格漸層＋漂過去又淡掉的紅色色塊＋一筆一筆寫出來的草寫 hello，
// 最後交給 👀 錶面（眼睛照舊，不改樣子；交接時眨一下）。
//
// 時間全部量自參考影片（@BetaProfiles 的 HomeView hello 渲染，1500²、29.97 fps；只在本機，不進版本庫），
// 表在 docs/plans/hello.md。這裡的 t＝螢幕亮起後的秒數（參考影片第 26 格＝t 0），所以 f(n) 把影格換成秒。
//
// 在哪裡播：HomePlay 2 第一次打開（之後才出操作提示）、新的人錄好臉、右鍵選單／設定的「打個招呼」、`--hello`。
// G4 白照 1.0 每次開機都寫。減少動態效果：不寫、不漂，靜態的 hello 交叉淡入淡出。點一下就跳到交接。
// 快照：HOMEPLAY_ANIM=hello:秒 把整段凍在第 t 秒（--screen-png --hello）。
import AppKit
import CoreGraphics

enum HelloTimeline {
    static let fps = 30000.0 / 1001
    /// 參考影片的影格 → t（螢幕亮起＝第 26 格：逐格量，亮面在這一格超過全亮的 25%）
    static func f(_ n: Double) -> Double { (n - 26) / fps }

    /// 亮起時只有 53% 亮（暗琥珀），第 54 格到全亮（量的平均色 #7C642F → #E9B64D）
    static func dim(_ t: Double) -> CGFloat {
        guard t >= 0 else { return 0 }
        return 0.53 + 0.47 * CGFloat(min(1, t / f(54)))   // 量的：第 27→42 格幾乎等速變亮
    }

    /// 寫字的節點：(影格, 寫到第幾段開頭)。字母之間照影片量的時間，字母裡面筆速固定
    static let writeKnots: [(frame: Double, curve: Int)] = [(85, 0), (108, 6), (112, 9), (119, 12), (126, 15), (135, 21)]
    static var writeStart: Double { f(writeKnots.first!.frame) }
    static var writeEnd: Double { f(writeKnots.last!.frame) }
    /// t 時寫到的弧長（設計座標）
    static func written(_ t: Double) -> CGFloat {
        let n = t * fps + 26
        let k = writeKnots
        if n <= k[0].frame { return 0 }
        for i in 1..<k.count where n <= k[i].frame {
            let a = HelloLettering.length(atCurve: k[i - 1].curve), b = HelloLettering.length(atCurve: k[i].curve)
            return a + (b - a) * CGFloat((n - k[i - 1].frame) / (k[i].frame - k[i - 1].frame))
        }
        return HelloLettering.sampled.length
    }

    /// 紅色色塊：(影格, 中心 x, y（螢幕 0…1）, 半徑, 不透明)。從左下進來、往右上、再往左下漂、淡掉
    static let blobKeys: [(n: Double, x: CGFloat, y: CGFloat, r: CGFloat, a: CGFloat)] = [
        (90, 0.17, 0.83, 0.00, 1), (93, 0.24, 0.73, 0.09, 1), (96, 0.31, 0.65, 0.18, 1),
        (99, 0.41, 0.58, 0.22, 1), (102, 0.49, 0.51, 0.26, 1), (105, 0.58, 0.44, 0.31, 1), (108, 0.65, 0.40, 0.345, 1),
        (111, 0.71, 0.37, 0.38, 1), (117, 0.76, 0.39, 0.39, 1), (123, 0.78, 0.43, 0.40, 1), (129, 0.75, 0.49, 0.42, 1),
        (135, 0.66, 0.54, 0.43, 1), (141, 0.58, 0.55, 0.40, 1), (150, 0.49, 0.55, 0.35, 0.97), (162, 0.42, 0.51, 0.32, 0.9),
        (174, 0.37, 0.48, 0.29, 0.78), (183, 0.34, 0.48, 0.26, 0.6), (189, 0.33, 0.48, 0.24, 0.34), (196, 0.33, 0.48, 0.22, 0),
    ]
    static func blob(_ t: Double) -> (x: CGFloat, y: CGFloat, r: CGFloat, a: CGFloat)? {
        let n = t * fps + 26, k = blobKeys
        guard n > k[0].n, n < k[k.count - 1].n else { return nil }
        for i in 1..<k.count where n <= k[i].n {
            let a = k[i - 1], b = k[i], u = CGFloat((n - a.n) / (b.n - a.n))
            let s = u * u * (3 - 2 * u)   // 節點之間平滑（速度在節點連續到眼睛看不出）
            return (a.x + (b.x - a.x) * s, a.y + (b.y - a.y) * s, a.r + (b.r - a.r) * s, a.a + (b.a - a.a) * s)
        }
        return nil
    }

    /// 參考影片最後一格（第 222 格）＝hello 停住的終點
    static var holdEnd: Double { f(222) }
    /// 交接給錶面：hello 整層淡出、底下的 👀 錶面露出來
    static let handoff = 0.5

    // 其他語言的招呼（見 HelloGreetings）：hello 停到第 175 格就換下一個
    static let extraSwap = 0.3, extraWrite = 1.1, extraHold = 1.3
    static var extrasStart: Double { f(175) }

    /// 減少動態效果：淡入 0.4 s、停 2.2 s、淡出 0.4 s
    static let staticFade = 0.4, staticHold = 2.2

    /// 交接開始的時間（hello 這一層開始淡出）
    static func handoffStart(extras: Int, reduce: Bool) -> Double {
        if reduce { return staticFade + staticHold }
        if extras == 0 { return holdEnd }
        return extrasStart + Double(extras) * (extraSwap + extraWrite + extraHold)
    }
    static func duration(extras: Int, reduce: Bool) -> Double {
        handoffStart(extras: extras, reduce: reduce) + (reduce ? staticFade : handoff)
    }
}

/// 暖色網格漸層：4×4 個顏色節點（量自參考影片最後幾格的取樣）＋慢慢的座標扭曲＋紅色色塊。
/// 在 128² 的小圖上逐點算，再放大畫上螢幕（放大的雙線性內插就是天然的柔化）。
/// prior art：ColorfulX／MulticolorGradient（MIT）是 GPU 上依距離混色；這裡量小，CPU 逐點就夠，沒有借程式。
enum HelloGradient {
    private typealias K = HPTokens.Hello
    static let size = 128

    private static func smooth(_ x: CGFloat) -> CGFloat { x * x * (3 - 2 * x) }

    /// (u, v) 的顏色（0…255）；t 驅動扭曲與色塊
    static func color(u: CGFloat, v: CGFloat, t: Double, blob: (x: CGFloat, y: CGFloat, r: CGFloat, a: CGFloat)?, drift: Bool) -> (CGFloat, CGFloat, CGFloat) {
        let tt = CGFloat(drift ? t : HelloTimeline.holdEnd)
        let w = 2 * CGFloat.pi
        let uu = u + 0.045 * sin(w * (v * 0.9 + 0.045 * tt + 0.1)) + 0.02 * sin(w * (u * 1.7 - 0.03 * tt))
        let vv = v + 0.045 * sin(w * (u * 0.8 - 0.04 * tt + 0.35)) + 0.02 * sin(w * (v * 1.5 + 0.025 * tt))
        let gx = max(0, min(2.9999, uu * 3)), gy = max(0, min(2.9999, vv * 3))
        let i = Int(gx), j = Int(gy), fx = smooth(gx - CGFloat(i)), fy = smooth(gy - CGFloat(j))
        func mix(_ a: (CGFloat, CGFloat, CGFloat), _ b: (CGFloat, CGFloat, CGFloat), _ k: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
            (a.0 + (b.0 - a.0) * k, a.1 + (b.1 - a.1) * k, a.2 + (b.2 - a.2) * k)
        }
        let grid = K.grid
        let top = mix(grid[j][i], grid[j][i + 1], fx), bottom = mix(grid[j + 1][i], grid[j + 1][i + 1], fx)
        var c = mix(top, bottom, fy)
        let glow = K.glow, gd = hypot(u - glow.x, (v - glow.y) * 1.25) / glow.r
        let gw = max(0, 1 - gd * gd); c = mix(c, glow.c, 0.8 * gw * gw)
        if let b = blob, b.a > 0, b.r > 0 {
            // 稍微扁、往右下拉長的軟邊色塊：內圈純紅，外圈混出橘色
            let dx = (u - b.x) / (b.r * 1.08), dy = (v - b.y) / (b.r * 0.94)
            let d = sqrt(dx * dx + dy * dy)
            let k = 1 - smooth(max(0, min(1, (d - 0.5) / 0.85)))
            c = mix(c, K.red, k * b.a)
        }
        return c
    }

    /// 整張漸層（size²，左上原點）；dim＝開機的暗琥珀
    static func image(t: Double, drift: Bool = true, showBlob: Bool = true) -> CGImage? {
        let n = size, dim = HelloTimeline.dim(t)
        let b = showBlob ? HelloTimeline.blob(t) : nil
        var buf = [UInt8](repeating: 255, count: n * n * 4)
        for y in 0..<n {
            let v = (CGFloat(y) + 0.5) / CGFloat(n)
            for x in 0..<n {
                let u = (CGFloat(x) + 0.5) / CGFloat(n)
                let c = color(u: u, v: v, t: t, blob: b, drift: drift)
                let o = (y * n + x) * 4
                buf[o] = UInt8(max(0, min(255, c.0 * dim))); buf[o + 1] = UInt8(max(0, min(255, c.1 * dim)))
                buf[o + 2] = UInt8(max(0, min(255, c.2 * dim)))
            }
        }
        guard let provider = CGDataProvider(data: Data(buf) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// 其他語言的招呼：沒有自己畫的手寫路徑，用系統字（PingFang／Hiragino 丸ゴ／SF Pro Rounded）排好，
/// 再用從左到右的柔邊遮罩「寫」出來（write-on reveal）。不打包任何字型、不用第三方筆畫資料。
struct HelloGreeting: Equatable {
    var text: String
    var fontNames: [String]
    var size: CGFloat

    static let zh = HelloGreeting(text: "你好", fontNames: ["PingFangTC-Regular", "PingFangSC-Regular"], size: 168)   // l10n-ignore：招呼本身就是那個語言，不翻
    static let ja = HelloGreeting(text: "こんにちは", fontNames: ["HiraMaruProN-W4", "HiraginoSans-W3"], size: 112)
    static let ko = HelloGreeting(text: "안녕하세요", fontNames: ["AppleSDGothicNeo-Regular"], size: 112)
    static let fr = HelloGreeting(text: "bonjour", fontNames: ["SFProRounded-Light", ".AppleSystemUIFontRounded-Light"], size: 140)
    static let es = HelloGreeting(text: "hola", fontNames: ["SFProRounded-Light", ".AppleSystemUIFontRounded-Light"], size: 150)

    /// --hello-cycle：官網素材用的整串
    static let cycle: [HelloGreeting] = [.zh, .ja, .fr, .es, .ko]

    /// 第一次打開：系統語言不是英文時，hello 之後接一個在地的招呼
    static func local(_ languages: [String] = Locale.preferredLanguages) -> [HelloGreeting] {
        guard let l = languages.first?.lowercased() else { return [] }
        if l.hasPrefix("zh") { return [.zh] }
        if l.hasPrefix("ja") { return [.ja] }
        if l.hasPrefix("ko") { return [.ko] }
        if l.hasPrefix("fr") { return [.fr] }
        if l.hasPrefix("es") { return [.es] }
        return []
    }

    var font: NSFont {
        for n in fontNames { if let f = NSFont(name: n, size: size) { return f } }
        if let d = NSFont.systemFont(ofSize: size, weight: .light).fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
        return NSFont.systemFont(ofSize: size, weight: .light)
    }
}

enum HelloIntro {
    /// HomePlay 2 第一次打開寫過 hello 沒有（1.0 的使用者升上來也會看到一次）
    static let shownKey = "HomePlay2HelloShown"
    nonisolated(unsafe) static var extras: [HelloGreeting] = []
    /// --hello-cycle
    nonisolated(unsafe) static var forceCycle = CommandLine.arguments.contains("--hello-cycle")
    /// 產品影片（HelloProduct）逐格給的時鐘：設了就不看真實時間
    nonisolated(unsafe) static var clockOverride: Double?
    /// 這一輪開始時記下的「減少動態效果」（中途切換不會讓時間軸跳）
    nonisolated(unsafe) static var reduce = false
    /// 暗的房間（夜間紅開著）：整層壓暗到 45%，不在半夜亮一大片橘
    nonisolated(unsafe) static var night = false
    /// 第一次打開：hello 停在最後一格當背景，接著出 HomePlay 自己的設定（Onboarding 卡）；卡收起才交給錶面
    nonisolated(unsafe) static var leadsIntoSetup = false
    /// 正停著等設定卡（hello 的時鐘凍在交接前）
    nonisolated(unsafe) static var holdingSince: Double?

    static var duration: Double { HelloTimeline.duration(extras: extras.count, reduce: reduce) }
    static var handoffStart: Double { HelloTimeline.handoffStart(extras: extras.count, reduce: reduce) }

    /// 第一次打開才回 true（順手記下來）
    static func takeFirstLaunch() -> Bool {
        guard !UserDefaults.standard.bool(forKey: shownKey) else { return false }
        UserDefaults.standard.set(true, forKey: shownKey)
        return true
    }
}

extension Face {
    /// 開始寫 hello（first：第一次打開，接在地語言的招呼）
    func beginHello(_ now: Double, local: Bool = false) {
        HelloIntro.reduce = HPMotion.reduceMotion
        HelloIntro.night = Shell.lowLight(self) && HelloIntro.clockOverride == nil
        HelloIntro.extras = HelloIntro.forceCycle ? HelloGreeting.cycle : (local ? HelloGreeting.local() : [])
        // 設定卡已經排著（第一次打開、--onboarding）：hello 寫完不收，當設定卡的背景
        HelloIntro.leadsIntoSetup = Onboarding.armed && HelloIntro.clockOverride == nil
        HelloIntro.holdingSince = nil
        sayHello(now)
        if !HelloIntro.leadsIntoSetup { blinkSoon(after: HelloIntro.handoffStart + 0.25) }   // 交接時 👀 眨一下出場
        // VoiceOver：螢幕是畫出來的，這裡直接念「hello」（還有接著的在地招呼）
        let spoken = (["hello"] + HelloIntro.extras.map(\.text)).joined(separator: ", ")
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: spoken, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// 點一下／按空白鍵、Return、Esc：直接跳到交接（不讓人等動畫播完）。
    /// 停著等設定卡的時候不吃（那一下歸設定卡）。回傳有沒有吃掉這次輸入
    @discardableResult
    func skipHello(_ now: Double) -> Bool {
        guard sayingHello, HelloIntro.clockOverride == nil, HPMotion.frozen("hello") == nil, HelloIntro.holdingSince == nil else { return false }
        let t = now - helloStart, hs = HelloIntro.handoffStart
        guard t < hs else { return false }
        helloStart = now - hs; forceDirty = true
        if !HelloIntro.leadsIntoSetup { blinkSoon(after: 0.25) }
        return true
    }

    /// 這一格的 hello 時間。第一次打開時停在交接前等設定卡；設定卡收起（點掉或 12 秒到）才往下走
    func helloTime(_ now: Double) -> Double {
        if let t = HelloIntro.clockOverride { return t }
        let hs = HelloIntro.handoffStart
        if let t = HPMotion.frozen("hello") {
            // 快照：凍在交接之後、又有設定卡排著＝拍「設定卡浮在 hello 背景上」那一格（t − 交接 秒之後）
            guard HelloIntro.leadsIntoSetup, t >= hs, Onboarding.armed || Onboarding.active else { return t }
            if HelloIntro.holdingSince == nil { HelloIntro.holdingSince = CACurrentMediaTime() - (t - hs) }
            return hs - 1e-3
        }
        if HelloIntro.leadsIntoSetup, helloStart >= 0 {
            if HelloIntro.holdingSince != nil {
                if Onboarding.armed || Onboarding.active { return hs - 1e-3 }
                // 設定卡收起了：從這一刻開始交接
                HelloIntro.holdingSince = nil; HelloIntro.leadsIntoSetup = false
                helloStart = now - hs; blinkSoon(after: 0.25)
            } else if now - helloStart >= hs, Onboarding.armed || Onboarding.active {
                HelloIntro.holdingSince = now
                return hs - 1e-3
            }
        }
        return now - helloStart
    }

    /// 停著等設定卡、而且設定卡該出來了（Onboarding.tickOnboarding 問這裡）
    var helloReadyForSetup: Bool { HelloIntro.holdingSince != nil }

    /// hello 這一層要不要蓋在錶面上面畫（交接中）
    func helloInHandoff(_ now: Double) -> Bool {
        helloStart >= 0 && (HelloIntro.holdingSince != nil || helloTime(now) >= HelloIntro.handoffStart)
    }

    /// 畫整個 hello 畫面（1024² 左上原點）。交接中整層淡出，底下的錶面已經畫好
    func drawHelloScene(_ g: CGContext, _ t: Double) {
        let reduce = HelloIntro.reduce
        let hs = HelloIntro.handoffStart
        var layerAlpha: CGFloat = 1
        if reduce {
            if t < HelloTimeline.staticFade { layerAlpha = CGFloat(t / HelloTimeline.staticFade) }
            if t > hs { layerAlpha = CGFloat(max(0, 1 - (t - hs) / HelloTimeline.staticFade)) }
        } else if t > hs {
            let k = min(1, (t - hs) / HelloTimeline.handoff); layerAlpha = CGFloat(1 - k * k * (3 - 2 * k))
        }
        guard layerAlpha > 0 else { return }
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        g.saveGState()
        if layerAlpha < 1 { g.setAlpha(layerAlpha); g.beginTransparencyLayer(auxiliaryInfo: nil) }
        // 開機前（只有產品影片會走到）：黑螢幕
        g.setFillColor(HPTokens.Hello.screenOff.cgColor); g.fill(full)
        if t >= 0, let img = HelloGradient.image(t: reduce ? HelloTimeline.holdEnd : t, drift: !reduce, showBlob: !reduce) {
            drawUpright(g, img, in: full)
        }
        if t >= 0 {
            if reduce { drawHelloWord(g, HelloLettering.sampled.length, alpha: 1) }
            else { drawHelloGreetings(g, t) }
        }
        if HelloIntro.night { g.setFillColor(HPTokens.Hello.nightDim.cgColor); g.fill(full) }
        if layerAlpha < 1 { g.endTransparencyLayer() }
        g.restoreGState()
    }

    /// hello 一筆寫出來；其他語言接在後面
    private func drawHelloGreetings(_ g: CGContext, _ t: Double) {
        let extras = HelloIntro.extras
        let swap = HelloTimeline.extraSwap, slot = swap + HelloTimeline.extraWrite + HelloTimeline.extraHold
        let x0 = HelloTimeline.extrasStart
        // hello：有後續語言時在 x0 之後淡出
        var helloAlpha: CGFloat = 1
        if !extras.isEmpty, t > x0 { helloAlpha = CGFloat(max(0, 1 - (t - x0) / swap)) }
        // 設定卡浮上來：字在 0.3 s 裡退掉，只留暖色漸層當玻璃卡的背景
        if let since = HelloIntro.holdingSince { helloAlpha *= CGFloat(max(0, 1 - (CACurrentMediaTime() - since) / 0.3)) }
        if helloAlpha > 0 { drawHelloWord(g, HelloTimeline.written(t), alpha: helloAlpha) }
        guard !extras.isEmpty, t > x0 else { return }
        let i = min(extras.count - 1, Int((t - x0) / slot)), local = t - x0 - Double(i) * slot
        var a: CGFloat = local < swap ? 0 : 1
        let write = max(0, min(1, (local - swap) / HelloTimeline.extraWrite))
        // 下一個要來了：這一個在最後 swap 秒淡出（最後一個留給交接）
        if i < extras.count - 1, local > slot - swap { a = CGFloat(max(0, 1 - (local - (slot - swap)) / swap)) }
        if local >= swap { drawTypesetGreeting(g, extras[i], reveal: CGFloat(write), alpha: a) }
    }


    /// hello 這個字：螢幕正中、寬約 40%（參考影片 107／266 px），筆寬 12.5（3.25 px × 3.85）
    func drawHelloWord(_ g: CGContext, _ s: CGFloat, alpha: CGFloat) {
        guard s > 0, alpha > 0 else { return }
        let b = HelloLettering.sampled.bounds
        let scale: CGFloat = 412 / b.width
        g.saveGState()
        g.setAlpha(alpha)
        g.translateBy(x: 512 - b.midX * scale, y: 512 - b.midY * scale)
        g.scaleBy(x: scale, y: scale)
        g.setBlendMode(.plusLighter)
        g.setLineCap(.round); g.setLineJoin(.round)
        let path = HelloLettering.path(upTo: s)
        // 柔光暈（影片裡筆畫外有一圈淡淡的亮）
        g.setShadow(offset: .zero, blur: 10 * scale, color: HPTokens.Hello.inkGlow.cgColor)
        // 視窗很小（130 pt 寬）時 12.5 只剩 1.6 pt：筆寬至少 2 pt，看得到
        let width = max(12.5, 2 / max(0.01, Typo.pointsPerUnit))
        g.setLineWidth(width / scale); g.setStrokeColor(HPTokens.Hello.ink.cgColor)
        g.addPath(path); g.strokePath()
        g.restoreGState()
    }

    /// 系統字排的招呼：柔邊遮罩從左到右掃過去（掃的速度固定）。字先畫進透明層，
    /// 還沒「寫到」的右邊用 destinationOut 擦掉（前緣 60 px 柔邊），整層再用加亮混合蓋上去
    private func drawTypesetGreeting(_ g: CGContext, _ h: HelloGreeting, reveal: CGFloat, alpha: CGFloat) {
        guard reveal > 0, alpha > 0 else { return }
        let font = h.font
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: h.text, attributes: [.font: font, .foregroundColor: HPTokens.Hello.ink]))
        let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let x = 512 - b.width / 2 - b.minX, base = 512 + (b.minY + b.maxY) / 2
        let edge: CGFloat = 60
        let front = x + b.minX - edge + (b.width + 2 * edge) * reveal   // 遮罩前緣（畫布 x）
        g.saveGState()
        g.setAlpha(alpha)
        g.setBlendMode(.plusLighter)
        g.beginTransparencyLayer(auxiliaryInfo: nil)
        g.setBlendMode(.normal)
        g.saveGState()
        g.setShadow(offset: .zero, blur: 10, color: HPTokens.Hello.inkGlow.cgColor)
        g.translateBy(x: x, y: base); g.scaleBy(x: 1, y: -1)
        g.textPosition = .zero; CTLineDraw(line, g)
        g.restoreGState()
        g.setBlendMode(.destinationOut)
        let cs = CGColorSpaceCreateDeviceGray()
        if let grad = CGGradient(colorsSpace: cs, colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1)] as CFArray, locations: [0, 1]) {
            g.saveGState(); g.clip(to: CGRect(x: front - edge, y: 0, width: edge, height: 1024))
            g.drawLinearGradient(grad, start: CGPoint(x: front - edge, y: 0), end: CGPoint(x: front, y: 0), options: [])
            g.restoreGState()
        }
        g.setFillColor(CGColor(gray: 0, alpha: 1)); g.fill(CGRect(x: front, y: 0, width: 1024, height: 1024))
        g.endTransparencyLayer()
        g.restoreGState()
    }
}

enum HelloSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        HelloLettering.selftest(check)
        let T = HelloTimeline.self
        check(abs(T.f(26)) < 1e-9 && abs(T.holdEnd - 196 / T.fps) < 1e-9, "hello：影格換算（亮起＝第 26 格）")
        check(T.written(T.f(84)) == 0 && T.written(T.writeEnd + 0.1) == HelloLettering.sampled.length, "hello：寫字起訖")
        // 字母節點：第 108 格剛好寫完 h
        check(abs(T.written(T.f(108)) - HelloLettering.length(atCurve: 6)) < 0.01, "hello：h 在第 108 格寫完")
        var mono = true, last: CGFloat = -1
        for i in 0...300 { let w = T.written(Double(i) / 60); if w < last { mono = false }; last = w }
        check(mono, "hello：筆只往前走")
        check(T.blob(T.f(80)) == nil && T.blob(T.f(200)) == nil && (T.blob(T.f(132))?.r ?? 0) > 0.3, "hello：紅色色塊只在第 90–196 格")
        check(T.dim(0) < 0.55 && T.dim(T.f(60)) == 1, "hello：開機暗琥珀到全亮")
        check(T.duration(extras: 0, reduce: false) == T.holdEnd + T.handoff && T.duration(extras: 0, reduce: true) < 3.5, "hello：長度（減少動態效果較短）")
        check(T.handoffStart(extras: 1, reduce: false) > T.holdEnd - 1, "hello：在地語言接在後面")
        check(HelloGreeting.local(["zh-Hant-TW"]) == [.zh] && HelloGreeting.local(["en-US"]).isEmpty && HelloGreeting.local(["ja-JP"]) == [.ja], "hello：在地語言")
        // 漸層：亮起後中間偏黃、紅塊最大時中心是紅
        let c = HelloGradient.color(u: 0.5, v: 0.44, t: T.holdEnd, blob: nil, drift: true)
        check(c.0 > 220 && c.1 > 180 && c.2 < 120, "hello：漸層中心淡黃")
        let r = HelloGradient.color(u: 0.72, v: 0.49, t: T.f(129), blob: T.blob(T.f(129)), drift: true)
        check(r.0 > 200 && r.1 < 60, "hello：紅色色塊")
    }
}

extension PetView {
    /// 右鍵選單「表盤 › 打個招呼」、設定「一般」底下的按鈕：再寫一次開機的 hello
    @objc func menuSayHello() { face.beginHello(CACurrentMediaTime()) }
}
