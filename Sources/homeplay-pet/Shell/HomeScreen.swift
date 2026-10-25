// 2.0 主畫面與 App 外殼（稿：hv-design/project/FacesHome.dc.html 右邊那台、LiveActivities.dc.html、Rules.dc.html）。
// 畫在錶面同一張 1024² 畫布上：Face.render 在外殼蓋住錶面時改叫 renderShell，之後照舊疊 CarPlay 過場、橫幅。
//
// 版面（1024 畫布，稿 492 → ×2.08）：
// - 2.0 R4：左上全大寫問候語（早安／午安／晚安＋名字），右上頭像（Contacts「我」的照片，沒有才用縮寫）；頂端中央一顆藥丸放 Live Activities，眼睛住在裡面；
// - 4 欄格線（照影片：左右邊距約 119、欄距 62、圖示 150、標籤 30）：天氣 2×2 與 App 圖示混排；沒有頁點；
// - 2.0 R3：桌布＝剛才錶面的畫面模糊 30 px＋壓暗 20%，上面一塊內縮 14 px 的玻璃面板（沒有錶面畫面才退回漸層）；
// - 點圖示：App 從圖示的位置長成全螢幕（彈簧，不是淡入），關掉時沿原路縮回去；中途可以打斷（從當下的值反向）。

import AppKit
import CoreImage

enum HomeItem: Equatable { case app(String), photos, upNext, weather, worldClock, sb(String) }   // 2.0 SpringBoard：.sb＝其他小工具、疊放、資料夾（key，Shell/SpringBoard/）   // 第六輪：右上的小工具換成「照片」（Shell/PhotosWidget.swift）；P02：可換天氣、世界時鐘

/// 2.0 R14：App 從圖示長成全螢幕（或縮回去）的兩條彈簧：放大 scale（0 圖示 … 1 全螢幕）與內容淡入 fade
struct AppMorph {
    var rect: CGRect
    var id: String
    var opening: Bool
    var scale: MotionValue
    var fade: MotionValue
}

/// 外殼的狀態（extension 不能存屬性，放這裡；桌寵只有一張 Face）
enum Shell {
    nonisolated(unsafe) static var nav = ShellNav()
    // 2.0 depth：計時器存起來（Shell/DepthLifecycle.swift 的 TimerStore），重開 HomePlay 接著倒數
    nonisolated(unsafe) static var timers = TimerStore.load() { didSet { if timers.timers != oldValue.timers { TimerStore.save(timers) } } }
    /// 鏡射到錶面計時器的到點時刻（CACurrentMediaTime）：用來分辨錶面那個計時器是不是我們放的
    nonisolated(unsafe) static var mirrorEnd: Double?
    /// 最近一次有人互動或靠近（沒人看 60 秒就回錶面）
    nonisolated(unsafe) static var lastActive = CACurrentMediaTime()
    static let idleTimeout = 60.0
    // 控制中心的開關（訪客模式、鎖定錶面先是旗標；亮度只壓暗桌寵的螢幕）
    nonisolated(unsafe) static var guestMode = false
    nonisolated(unsafe) static var lockFace = false
    nonisolated(unsafe) static var brightness: CGFloat = 1
    // 過場
    nonisolated(unsafe) static var appMorph: AppMorph?
    /// 動效包：App 是從哪一格（圖示或小工具）打開的——關的時候縮回同一個地方
    nonisolated(unsafe) static var openedFrom: (id: String, rect: CGRect, screen: ShellScreen)?
    nonisolated(unsafe) static var pillFrom: (rect: CGRect, start: Double)?
    nonisolated(unsafe) static var pillT: CGFloat = 0          // 0 小藥丸 … 1 長成 Live Activity
    nonisolated(unsafe) static var ccT: CGFloat = 0            // 控制中心出現的進度（ccAnim 的值；拖著時直接跟手）
    /// 2.0 R14：控制中心的彈簧（放手把速度交給它）；拖著時 ccDragging，ccT 1:1 跟著指標
    nonisolated(unsafe) static var ccAnim = MotionValue("cc", spring: .smooth, from: 0, to: 0, now: 0)
    nonisolated(unsafe) static var ccDragging = false
    /// 2.0 R3：主畫面的桌布＝剛才錶面的畫面模糊 30 px＋壓暗 20%
    nonisolated(unsafe) static var homeBackdrop: CGImage?
    /// 2.0 R11：接管（門鈴、Handoff）：舊畫面放大 5%＋模糊 20 px、交叉淡化（影片 v2 00:31.80–00:32.30 量到 0.5 s）
    nonisolated(unsafe) static var takeover: (sharp: CGImage, blurred: CGImage, anim: MotionValue)?
    static let takeoverSpring = HPMotion.T.takeoverFade.spring   // 動效包：參數表（Design/HPMotionTable.swift）：先放大模糊 0.2 s、再交叉淡化
    /// 動效包：接管的新畫面（第一格拍下來糊 20 px），交叉淡化時從模糊變清楚
    nonisolated(unsafe) static var takeoverNew: CGImage?
    nonisolated(unsafe) static var ccBackdrop: CGImage?        // 控制中心底下的霧化畫面（打開那一刻拍的）
    nonisolated(unsafe) static var lastPageAt = 0.0
    nonisolated(unsafe) static var lastActivitySecond = -1
    nonisolated(unsafe) static var lastWeatherVersion = -1
    nonisolated(unsafe) static var homeHue: CGFloat?
    nonisolated(unsafe) static var homeLayer: (key: String, image: CGImage)?
    nonisolated(unsafe) static var wallpaper: (key: String, image: CGImage)?
    /// 2.0 R11／R14：影片 v1 0:47.125（卡片開始動的第一格）→47.25 滿版：放大 0.12 s 看起來結束（47.084 是手指碰到，我們從放開才開始）；
    /// 內容 47.29 起淡入、47.42 滿（放大起算晚 0.15 s、0.15 s 收完）。臨界阻尼、無回彈。逐格對照：scratchpad/real/anim-appopen.png
    static let morphSpring = HPMotion.T.appOpen.spring
    static let fadeSpring = HPMotion.T.appContent.spring
    static let fadeDelay = HPMotion.T.appContent.delay
    /// 錶面 → 主畫面：眼睛膠囊縮成頂端藥丸（跟換頁同一段時間收完）
    static let pillSpring = HPMotion.T.pill.spring

    // MARK: 版面

    static let side: CGFloat = 1024
    // 第五輪：照官方主畫面（home-screen-erica 正視校正）：圖示 152、左右邊距 99、欄距 225；首列頂 241、列距 240（HPTokens.Home）
    static let margin: CGFloat = HPTokens.Home.gridMargin, colW: CGFloat = HPTokens.Home.iconSide
    static let colGap: CGFloat = HPTokens.Home.columnPitch - HPTokens.Home.iconSide
    static let gridTop: CGFloat = HPTokens.Home.gridTop, rowH: CGFloat = 218, rowGap: CGFloat = HPTokens.Home.rowPitch - 218
    static let iconSide: CGFloat = HPTokens.Home.iconSide
    static func cell(_ col: Int, _ row: Int, w: Int = 1, h: Int = 1) -> CGRect {
        CGRect(x: margin + CGFloat(col) * (colW + colGap), y: gridTop + CGFloat(row) * (rowH + rowGap),
               width: CGFloat(w) * colW + CGFloat(w - 1) * colGap, height: CGFloat(h) * rowH + CGFloat(h - 1) * rowGap)
    }
    /// 主畫面：第六輪完全照官方——左上 2×2 是 FaceTime／家庭／音樂／訊息，右上 2×2 是「照片」小工具；
    /// 第三列照官方內建 App 清單的順序往後排（Alarms、Calendar、Podcasts、Reminders），其他在「全部 App」
    /// P02：每位家人一份（People/PersonHome.swift，依 WhoIsLooking／頭像那個人載入）；沒存過的人照上面這份官方預設
    static func homeItems() -> [(CGRect, HomeItem)] { SB.homeItems() }   // 2.0 SpringBoard：多頁、資料夾、各大小小工具（Shell/SpringBoard/SBBoard.swift）
    /// 全部 App：4 欄照順序排
    static func libraryItems() -> [(CGRect, HomeItem)] { SB.libraryItems() }   // 2.0 SpringBoard：App 資料庫（排序、搜尋）
    static func libraryItemsP02() -> [(CGRect, HomeItem)] {
        // 全部 App 有 4 列：從頭像底下（192）開始，列距 202（圖示 150＋名稱）
        AppRegistry.visible.enumerated().map {   // 2.0 P10：食譜在 Safari 裡，不另外一格
            (CGRect(x: margin + CGFloat($0.offset % 4) * (colW + colGap), y: 192 + CGFloat($0.offset / 4) * 202, width: colW, height: 194), .app($0.element.id))
        }
    }
    /// 圖示在格子裡的方塊（標籤在下面）
    static func iconRect(in cell: CGRect) -> CGRect {
        CGRect(x: cell.midX - iconSide / 2, y: cell.minY, width: iconSide, height: iconSide)
    }
    /// small 小工具：正方形，邊長＝兩列圖示的外緣（上下對齊圖示），置中在兩欄上（官方 Photos 391²，比兩欄圖示的外緣左右各多 7）
    static func widgetRect(col: Int, row: Int) -> CGRect {
        let a = iconRect(in: cell(col, row)), b = iconRect(in: cell(col + 1, row + 1))
        let side = b.maxY - a.minY, mid = (a.minX + b.maxX) / 2
        return CGRect(x: mid - side / 2, y: a.minY, width: side, height: side)
    }
    static let widgetRadius: CGFloat = HPTokens.Radius.widget   // 第五輪：官方 Photos 小工具量到約 56

    // 頂端藥丸：平常 208×62（稿 100×30）；2.0 P03：長成 Live Activity 時照內容變寬、高度不變（compact／minimal，Shell/LiveActivityStack.swift），上緣不動
    static let pillTop: CGFloat = 46
    static func pillRect(_ t: CGFloat) -> CGRect {
        lerp(CGRect(x: 512 - 104, y: pillTop, width: 208, height: 62), LiveActivityStack.compactPill, t)
    }
    /// 2.0 R1：App 左上的返回鈕＝88 px 玻璃圓鈕（✕／‹），圓心在螢幕圓角的圓心上（HPTokens.backButton）；大標題由 App 自己畫在旁邊
    static let navHeight: CGFloat = 88
    static var closeButton: CGRect { HPTokens.backButton }
    /// 玻璃膠囊（控制層）：半透明白、上緣亮邊、底下一點陰影
    static func drawGlassCapsule(_ g: CGContext, _ r: CGRect, dark: Bool = true) {
        let path = CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: 4), blur: 18, color: NSColor(white: 0, alpha: dark ? 0.35 : 0.12).cgColor)
        g.addPath(path); g.setFillColor(NSColor(white: dark ? 0.32 : 1, alpha: dark ? 0.55 : 0.72).cgColor); g.fillPath()
        g.restoreGState()
        g.saveGState()
        g.addPath(path); g.setLineWidth(2.5); g.replacePathWithStrokedPath(); g.clip()
        let rim = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                             colors: [NSColor(white: 1, alpha: 0.5).cgColor, NSColor(white: 1, alpha: 0.06).cgColor, NSColor(white: 1, alpha: 0.22).cgColor] as CFArray,
                             locations: [0, 0.5, 1])!
        g.drawLinearGradient(rim, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
        g.restoreGState()
    }

    static var currentApp: PetApp? {
        if case .app(let id) = nav.screen { return AppRegistry.app(id) }
        return nil
    }

    // MARK: 計時器

    static func addTimer(minutes: Double, label: String, face: Face) -> Int {
        let id = timers.add(seconds: minutes * 60, label: label, now: TimersApp.wallNow)
        reconcileTimers(face, now: CACurrentMediaTime())
        face.forceDirty = true
        log("shell timer add \(Int(minutes * 60))s")
        return id
    }
    static func removeTimer(_ id: Int, face: Face) {
        timers.remove(id)
        reconcileTimers(face, now: CACurrentMediaTime())
        face.forceDirty = true
        log("shell timer stop")
    }

    /// 帳 ↔ 錶面計時器：到點出橫幅；最快到點的那組鏡射到錶面（番茄鐘在跑時不碰）；
    /// 錶面上別處開的計時器（右鍵選單）收進帳裡；右鍵取消了我們放的那個就從帳裡拿掉。有變化回 true
    @discardableResult
    static func reconcileTimers(_ face: Face, now: Double) -> Bool {
        let wall = TimersApp.wallNow
        var changed = false
        for t in timers.expire(now: wall) {
            changed = true
            if !face.pomodoro.active { TimerChime.start() }   // 2.0 depth：到點會響（Shell/DepthLifecycle.swift）
            let texts = (String(format: L("shell.timer.doneTitle", "%@ · 现在"), t.label), L("timer.banner.done", "时间到了"))
            if t.id == mirroredID, face.timerEnd == nil, face.bannerShowing {
                face.showBanner(now: now, texts: texts)              // 錶面這一幀先到點了：只換橫幅的字
            } else {
                if t.id == mirroredID { face.cancelTimer() }
                face.showBanner(now: now, texts: texts)
                if !face.pomodoro.active { face.onTimerDone?() }    // 番茄鐘在跑時不要讓它跳下一段
            }
            if t.id == mirroredID { mirroredID = nil; mirrorEnd = nil }
        }
        if face.pomodoro.active { mirroredID = nil; mirrorEnd = nil; return changed }
        let faceEnd = face.timerEnd
        let ours = faceEnd != nil && mirrorEnd.map { abs($0 - faceEnd!) < 0.5 } == true
        if let fe = faceEnd, !ours {
            // 右鍵選單或別處開的：收進帳裡
            let left = fe - now
            if left > 0.5 {
                let id = timers.add(seconds: left, label: face.timerLabel, now: wall, total: face.timerTotal)
                mirroredID = id; mirrorEnd = fe; changed = true
                return changed
            }
        }
        if faceEnd == nil, mirrorEnd != nil {
            // 我們放的錶面計時器不見了，帳裡那組卻還沒到：右鍵取消了
            if let m = mirroredID, let t = timers.timer(m), t.left(wall) > 1 { timers.remove(m) }
            mirroredID = nil; mirrorEnd = nil; changed = true
        }
        if let want = timers.primary {
            let wantEnd = now + want.left(wall)
            if mirroredID != want.id || mirrorEnd.map({ abs($0 - wantEnd) > 1 }) ?? true {
                face.startTimer(seconds: want.left(wall), now: now, total: want.total)
                mirroredID = want.id; mirrorEnd = face.timerEnd; changed = true
            }
        } else if ours {
            face.cancelTimer(); mirroredID = nil; mirrorEnd = nil; changed = true
        }
        return changed
    }
    static var mirroredID: Int? {
        get { timers.mirrored }
        set { timers.mirrored = newValue }
    }

    // MARK: 小零件

    static func drawAppIcon(_ g: CGContext, face: Face, icon: AppIcon, in r: CGRect, appID: String? = nil) {
        // 使用者 2026-10-25：預設用系統原生圖示（執行時從這台 Mac 讀，不打包、不上官網）。
        // Mac 上有同一個 App 的（音樂、訊息、家庭、提醒事項、天氣、Podcast、設定、FaceTime）用系統的；
        // Mac 沒有對應 App 的（鬧鐘、計時器、世界時鐘、對講）和會跟著日期變的行事曆，才用 HPIcons；我們自己的 App（食譜、ClioTalk）用 HPIcons。
        if let img = icon.image {   // 2.0 Web App：抓到的圖示（正向的圖，轉正貼上、裁成 App 圖示的連續圓角）
            g.saveGState(); g.addPath(continuousRoundedRect(r, radius: r.width * 0.2237)); g.clip(); face.drawUpright(g, img, in: r); g.restoreGState(); return
        }
        let px = Int((r.width * face.renderPixelScale).rounded())
        let systemPath = icon.system ?? (appID == "facetime" ? "/System/Applications/FaceTime.app" : nil)
        if appID != "worldclock", let p = systemPath, let img = AppIconArt.systemIcon(p, px: max(64, px)) {
            // systemIcon 畫在 makeImage 的翻轉畫布上，出來已經是上下顛倒的；直接畫在同樣翻轉的畫布上剛好轉正
            g.saveGState(); g.interpolationQuality = .high; g.draw(img, in: r); g.restoreGState(); return
        }
        // 鬧鐘、計時器、世界時鐘、對講：讀 HomeView 官網的官方圖示（Shell/OfficialIcons.swift，快取在本機；同樣是翻轉畫布上的圖，直接畫）
        if let img = OfficialIcons.icon(appID, px: max(64, px)) { g.saveGState(); g.interpolationQuality = .high; g.draw(img, in: r); g.restoreGState(); return }
        if let k = appID.flatMap(HPIcons.kind(forID:)) ?? HPIcons.kind(forSymbol: icon.symbol) { HPIcons.draw(k, g, in: r); return }
        if icon.calendarDate { HPIcons.draw(.calendar, g, in: r); return }
        AppIconArt.drawGlassy(g, face: face, icon: icon, in: r)
    }
    static func drawAppIconFlat(_ g: CGContext, face: Face, icon: AppIcon, in r: CGRect) {
        let path = continuousRoundedRect(r, radius: r.width * 0.2237)   // App 圖示的連續圓角比例
        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: -r.height * 0.04), blur: r.height * 0.12, color: NSColor(white: 0, alpha: 0.22).cgColor)
        g.addPath(path); g.setFillColor(icon.color.cgColor); g.fillPath()
        g.restoreGState()
        g.saveGState(); g.addPath(path); g.clip()
        let cs = CGColorSpace(name: CGColorSpace.sRGB)
        let sheen = CGGradient(colorsSpace: cs, colors: [NSColor(white: 1, alpha: 0.18).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(sheen, start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.midY), options: [])
        g.restoreGState()
        face.drawSymbol(g, icon.symbol, in: r.insetBy(dx: r.width * 0.22, dy: r.height * 0.24), color: icon.glyph)
    }

    static func drawRoundButton(_ g: CGContext, face: Face, _ r: CGRect, symbol: String, tint: NSColor, glyph: NSColor) {
        g.setFillColor(tint.cgColor); g.fillEllipse(in: r)
        face.drawSymbol(g, symbol, in: r.insetBy(dx: r.width * 0.32, dy: r.height * 0.32), color: glyph, weight: .bold)
    }

    /// 一張圖的平均色（縮到 4×4 再平均）
    static func averageColor(_ img: CGImage) -> NSColor? {
        var px = [UInt8](repeating: 0, count: 4 * 4 * 4)
        guard let ctx = CGContext(data: &px, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 4, height: 4))
        var r = 0.0, gg = 0.0, b = 0.0
        for i in stride(from: 0, to: px.count, by: 4) { r += Double(px[i]); gg += Double(px[i + 1]); b += Double(px[i + 2]) }
        let n = 16.0 * 255
        return NSColor(srgbRed: r / n, green: gg / n, blue: b / n, alpha: 1)
    }

    /// 主畫面桌布的色相：取自錶面畫面；太灰（黑、System 6）就用時段色票的主色塊
    static func hue(fromFace img: CGImage?, face: Face) -> CGFloat {
        if let img, let c = averageColor(img)?.usingColorSpace(.sRGB), c.saturationComponent > 0.14 { return c.hueComponent }
        let pal = Face.palette(hour: face.hourNow, aqua: face.aqua)
        return NSColor(srgbRed: pal.blobs[0].0.r, green: pal.blobs[0].0.g, blue: pal.blobs[0].0.b, alpha: 1).usingColorSpace(.sRGB)?.hueComponent ?? 0.9
    }

    static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }
    static func ease(_ x: CGFloat) -> CGFloat { 1 - pow(1 - max(0, min(1, x)), 3) }

    /// 2.0 R3：錶面畫面 → 主畫面桌布（模糊＋壓暗，第五輪的值在 HPTokens.Home）；沒有畫面就清掉（退回漸層）
    static func captureHomeBackdrop(_ img: CGImage?) {
        guard let img else { homeBackdrop = nil; return }
        let ci = CIImage(cgImage: img)
        let k = Double(img.width) / 1024
        // 第五輪：σ 30 → 18、× 0.8 → 0.72（官方面板底下還看得到錶面的大數字柱形；HPTokens.Home）
        let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: Double(HPTokens.Home.wallpaperBlur) * k).cropped(to: ci.extent)
        // 亮的錶面（淺粉的照片錶面、白天的天氣）再多壓一點：平均亮度壓到官方面板內的程度（HPTokens.Home.wallpaperMaxLum），白色標籤才讀得到
        var d = HPTokens.Home.wallpaperDim
        if let avg = averageColor(img)?.usingColorSpace(.sRGB) {
            let lum = 0.2126 * avg.redComponent + 0.7152 * avg.greenComponent + 0.0722 * avg.blueComponent
            if lum * d > HPTokens.Home.wallpaperMaxLum { d = HPTokens.Home.wallpaperMaxLum / lum }
        }
        // Core Image 在線性光裡乘：sRGB 值要 × d，線性值就 × d^2.2（之前的「× 0.8」其實只壓暗了約 10%）
        let dl = pow(d, 2.2)
        let dark = blurred.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: dl, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: dl, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: dl, w: 0)])
        homeBackdrop = Face.ciContext.createCGImage(dark, from: ci.extent)
        homeLayer = nil
    }

    /// 2.0 R11：接管畫面（門鈴、Handoff 之類從別處跳進來的全螢幕）：拍下現在這一幀，之後幾幀蓋在新畫面上放大、模糊、淡出
    static func beginTakeover(_ face: Face, now: Double = CACurrentMediaTime()) {
        guard let old = face.lastFrame else { return }
        let ci = CIImage(cgImage: old)
        let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: Double(old.width) / 1024 * 20).cropped(to: ci.extent)
        takeover = (old, Face.ciContext.createCGImage(blurred, from: ci.extent) ?? old,
                    MotionValue("takeover", spring: takeoverSpring, from: 0, to: 1, now: now, delay: HPMotion.T.takeoverFade.delay))
        takeoverNew = nil
        face.forceDirty = true
    }

    /// App 變形：從圖示的框長成全螢幕（open），或縮回去；同一個 App 又反向時從當下的值接著走
    static func beginMorph(rect: CGRect, id: String, opening: Bool, now: Double) {
        if var m = appMorph, m.id == id {
            m.opening = opening; m.rect = rect
            m.scale.retarget(opening ? 1 : 0, now: now, spring: (opening ? HPMotion.T.appOpen : HPMotion.T.appClose).spring)
            m.fade.retarget(opening ? 1 : 0, now: now, spring: (opening ? HPMotion.T.appContent : HPMotion.T.appCloseContent).spring)   // 動效包：關的時候內容 80 ms 先淡掉
            if opening { m.fade.delay = max(0, fadeDelay - Double(m.scale.value(now)) * fadeDelay) }
            appMorph = m
            return
        }
        appMorph = AppMorph(rect: rect, id: id, opening: opening,
                            scale: MotionValue(opening ? "appopen" : "appclose", spring: morphSpring, from: opening ? 0 : 1, to: opening ? 1 : 0, now: now),
                            fade: MotionValue(opening ? "appopen" : "appclose", spring: opening ? fadeSpring : HPMotion.T.appCloseContent.spring, from: opening ? 0 : 1, to: opening ? 1 : 0, now: now,
                                              delay: opening ? fadeDelay : 0))
    }

    /// --appearance light|dark：快照強制淺／深（HPTokens.dark 開機時已照它設好），不跟環境走
    static let appearanceForced = CommandLine.arguments.contains("--appearance")
    /// 房間光（「房間光線」開著時的相機估計，0.4…1.5）；nil＝不知道
    nonisolated(unsafe) static var roomIntensity: Float?
    /// 2.0 第四輪（使用者決定 #3）：夜間紅色只看房間亮度——「房間光線」的鏡頭估計很暗，或控制中心的「夜間」手動打開。
    /// 不再用 22:00–06:00 的時間備援：鏡頭關著（roomIntensity == nil）就不會自己進夜間。
    static func lowLight(_ face: Face) -> Bool { nightFrom(room: roomIntensity, manual: manualNight) }
    static func nightFrom(room: Float?, manual: Bool) -> Bool { manual || (room.map { $0 < 0.5 } ?? false) }
    /// 控制中心「夜間」：手動進夜間（存偏好）；快照用 --night（不存）
    static let nightKey = "shell.nightManual"
    nonisolated(unsafe) static var manualNight: Bool = CommandLine.arguments.contains("--night") || UserDefaults.standard.bool(forKey: nightKey) {
        didSet { if !CommandLine.arguments.contains("--night") { UserDefaults.standard.set(manualNight, forKey: nightKey) } }
    }
    /// 2.0 P07：夜間的強調色。夜間的錶面／主畫面會整面經 drawNightFace 的「亮度→紅」映射（只留亮度），
    /// 所以強調色要畫白才會留下最亮的紅——直接畫紅（舊的 #EB1F1A）會沉成 2:1 上下的深紅，看不清（HIG-LA-203）。
    /// 自畫夜間紅的 Modular（nightOwnPalette）不走映射，直接用 HPTokens.Night。
    static func nightTint(_ c: NSColor, _ face: Face) -> NSColor { face.nightRed ? .white : c }
    /// 2.0 P07 True Tone：房間色溫（-1 冷 … +1 暖；鏡頭關著＝0），Face.render 收尾拿它微調整面白點（Faces/TrueTone.swift）
    nonisolated(unsafe) static var trueToneWarmth: Float = 0
    /// 夜間整面轉紅時要原樣貼回去的那一塊（Live Activity 長開時只有眼睛那一段；nil＝照錶面上的眼睛膠囊算）
    nonisolated(unsafe) static var nightKeep: CGRect?

    /// 2.0 R4：主畫面左上的問候語（全大寫；認得出人就第二行放名字）
    static func greeting(hour: Double) -> [String] {
        let h = Int(hour)
        let word = h >= 5 && h < 12 ? L("home.greeting.morning", "早上好")
                 : h >= 12 && h < 18 ? L("home.greeting.afternoon", "下午好") : L("home.greeting.evening", "晚上好")
        let reg = PeopleRegistry.shared
        guard let p = demoPerson ?? PersonalGate.avatarPerson(PersonalGate.inputs, people: reg.people, owner: reg.owner) else { return [word.uppercased()] }
        let name = p.name.split(separator: " ").first.map(String.init) ?? p.name
        guard !name.isEmpty else { return [word.uppercased()] }
        return [String(format: L("home.greeting.comma", "%@，"), word).uppercased(), name.uppercased()]
    }

    /// 第四輪：--demo-official 的主畫面不顯示真名（示範名字 Erica，照官方主畫面的示範）；
    /// 第五輪：頭像用示範的 👀 人物（紫底長捲髮，對應官方紫底的 Memoji），不讀真的帳號頭像或聯絡人照片
    static var demoPerson: Person? {
        OfficialDemo.on ? Person(id: "demo-erica", name: "Erica", colorIndex: 3, isOwner: true,   // l10n-ignore：示範人名
                                 avatar: HPAvatar.Style(background: 4, skin: 3, hair: HPAvatar.Hair.long.rawValue, hairColor: 0, face: HPAvatar.FaceShape.oval.rawValue),
                                 avatarSource: .eyes) : nil
    }
    /// 問候語用的鐘點：--demo-official 照示範時間（10:09 → GOOD MORNING），不照這台 Mac 的現在
    static func greetingHour(_ face: Face) -> Double {
        guard OfficialDemo.on else { return face.hourNow }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Face.displayDate)
        return Double(c.hour ?? 10) + Double(c.minute ?? 0) / 60
    }

    /// 第五輪 C：主畫面靜態層（含會跟著日期變的行事曆圖示）認的「哪一天」；換日（午夜）就換 key、整層重畫
    static func homeDayKey(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
    /// 上一次畫主畫面時的那一天（tickShell 比對，換日就要重畫）
    nonisolated(unsafe) static var homeDrawnDay: String?
    static func dayChanged(drawn: String?, now: Date) -> Bool { drawn.map { $0 != homeDayKey(now) } ?? false }

    static var initial: String {
        let n = NSFullUserName().trimmingCharacters(in: .whitespaces)
        return n.first.map { String($0).uppercased() } ?? "A"
    }
}

// MARK: - 錶面上的外殼：tick 與 render（main.swift 的 Face.tickLive／render 各一行呼叫）

extension Face {
    var shellCoversFace: Bool { Shell.nav.screen.coversFace }

    /// 每幀：計時器對帳、過場、藥丸、App 自己的 tick；要重畫回 true
    func tickShell(_ now: Double, _ dt: Double) -> Bool {
        if OfficialIcons.onLoaded == nil { OfficialIcons.onLoaded = { [weak self] in Shell.homeLayer = nil; self?.forceDirty = true } }   // 官網圖示抓好就重畫
        var dirty = Shell.reconcileTimers(self, now: now)
        if AlarmCenter.shared.tick(self, now) { dirty = true }   // 2.0: 鬧鐘到點（Shell/Apps/AlarmsApp.swift）
        let covers = shellCoversFace
        if Shell.appMorph != nil || Shell.pillFrom != nil { dirty = true }
        if let m = Shell.appMorph, m.scale.done(now), m.fade.done(now) { Shell.appMorph = nil }
        if let t = Shell.takeover { dirty = true; if t.anim.done(now), !Shell.takeoverHeld { Shell.takeover = nil } }   // 2.0 promo：Handoff 等網頁出圖時先停住
        if HPGlass.animating(now) || Anim.active { dirty = true }   // 動效包：sheet、數字轉場、清單也在動
        // 2.0 R2／R12：暗處（夜裡或房間光很暗）App 轉深色、錶面轉紅
        if !Shell.appearanceForced {
            let d = Shell.lowLight(self) || CCSystem.darkAppearance   // 2.0 cc：控制中心的「深色模式」
            if d != HPTokens.dark { HPTokens.dark = d; Shell.homeLayer = nil; dirty = true }
        }
        if let p = Shell.pillFrom, now - p.start >= Face.transitionDuration { Shell.pillFrom = nil }
        // 藥丸：有 Live Activity 就長大
        let act = covers ? shellActivity(now) : nil
        let goal: CGFloat = act == nil ? 0 : 1
        if Shell.pillT != goal {
            Shell.pillT += (goal - Shell.pillT) * CGFloat(1 - exp(-dt / 0.12))
            if abs(goal - Shell.pillT) < 0.003 { Shell.pillT = goal }
            dirty = true
        }
        if LiveActivityStack.tick(self, now) { dirty = true }   // 2.0 P03：展開的彈簧、音量條
        if act != nil {
            let s = Int(Date().timeIntervalSince1970)
            if s != Shell.lastActivitySecond { Shell.lastActivitySecond = s; dirty = true }
        }
        // 控制中心進出：彈簧（拖著時 1:1 跟手，放手由 ShellInput 把速度交給 ccAnim）
        if !Shell.ccDragging {
            let ccGoal: CGFloat = Shell.nav.overlay == .controlCenter ? 1 : 0
            if Shell.ccAnim.to != ccGoal { Shell.ccAnim.retarget(ccGoal, now: now) }
            let v = Shell.ccAnim.done(now) ? ccGoal : Shell.ccAnim.value(now)
            if v != Shell.ccT {
                Shell.ccT = v
                if Shell.ccT <= 0.0005 { Shell.ccT = 0; Shell.ccBackdrop = nil }
                dirty = true
            }
        }
        if Shell.nav.overlay == .controlCenter, ControlCenter.tick(now) { dirty = true }
        Shell.noteOpenApp()   // 2.0 depth：換掉的 App 收尾（Shell/DepthLifecycle.swift）
        if covers {
            switch Shell.nav.screen {
            case .app: if let a = Shell.currentApp, a.tick(now) { dirty = true }
            case .home, .library:
                if Shell.dayChanged(drawn: Shell.homeDrawnDay, now: Face.displayDate) { dirty = true }   // 第五輪 C：午夜換日，行事曆圖示跟著換
                if Shell.homeWidgetsDirty() { dirty = true }   // P02：世界時鐘換分鐘、天氣資料到了
                if SB.tick(self, now: now) { dirty = true }    // 2.0 SpringBoard：晃動、拖曳、換頁、資料夾
            default: break
            }
        }
        return dirty
    }

    /// 頂端藥丸要顯示的 Live Activity：照 AppRegistry 的順序，計時器優先（2.0 P03：全部的在 shellActivities）
    func shellActivity(_ now: Double) -> LiveActivity? { shellActivities(now).first }

    /// App 的畫面；個人 App 在不是主人時換成「需要主人」
    func renderShellApp(_ app: PetApp, _ g: CGContext, _ rect: CGRect, _ now: Double) {
        if PersonalGate.locks(app.id) { drawPersonalLock(g, app: app) } else { app.render(into: g, face: self, rect: rect, now: now) }
    }

    /// 外殼蓋住錶面時，render 叫這裡畫整面
    func renderShell(_ g: CGContext, _ now: Double) {
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        HPGlass.discard()
        if let m = Shell.appMorph {
            let t = max(0, min(1, m.scale.value(now))), fade = max(0, min(1, m.fade.value(now)))
            // 底下是主畫面（或全部 App）；App 從圖示的框長成整面（關掉時沿原路縮回去）
            // 動效包：底下的主畫面以來源為中心往前推一點（官方 v1 0:47.1–47.2：旁邊的圖示跟著放大）；減少動態效果時不動
            let push = HPMotion.reduceMotion ? 1 : 1 + 0.08 * t, pc = CGPoint(x: m.rect.midX, y: m.rect.midY)
            g.saveGState(); g.translateBy(x: pc.x, y: pc.y); g.scaleBy(x: push, y: push); g.translateBy(x: -pc.x, y: -pc.y)
            drawShellBase(g, now, screen: Shell.nav.screen == .app(m.id) ? Shell.nav.appReturn : Shell.nav.screen)
            HPGlass.flush(g, face: self, now: now)
            g.restoreGState()
            if let app = AppRegistry.app(m.id) {
                // 動效包：小工具（2×2）開的 App 從整塊小工具的位置、大小、圓角長出來（v1 0:47.125），圖示開的從圖示長出來
                let fromWidget = m.rect.width > Shell.colW * 1.5
                let icon = fromWidget ? m.rect : Shell.iconRect(in: m.rect)
                let r0 = fromWidget ? Shell.widgetRadius : icon.width * 0.2237
                // 減少動態效果：不縮放，整面交叉淡化
                let r = HPMotion.reduceMotion ? full : Shell.lerp(icon, full, t)
                let radius = r0 + (Screen.cornerRadius - r0) * (HPMotion.reduceMotion ? 1 : t)
                // App 先畫在自己的 1024² 畫布上（玻璃照常拿那一幀當背景），再整張縮放貼上
                let sc = renderPixelScale, px = Int((1024 * sc).rounded())
                let page = makeImage(px, px) { c in
                    c.scaleBy(x: sc, y: sc)   // makeImage 已經是左上原點
                    c.setFillColor(HPTokens.bg.cgColor); c.fill(full)
                    renderShellApp(app, c, full, now)   // 2.0: 個人 App 在訪客時是「需要主人」
                    if app.showsCloseButton || PersonalGate.locks(app.id) { drawShellNav(c, app) }
                    HPGlass.flush(c, face: self, now: now)
                    if app.showsClock { drawShellClock(c) }
                }
                g.saveGState()
                if HPMotion.reduceMotion { g.setAlpha(fade) }
                g.addPath(continuousRoundedRect(r, radius: radius)); g.clip()
                // 白卡從圖示長出來：一開始還看得到圖示，很快換成 App 的底色；內容等放大快完才淡入（關掉時反過來）
                let card = min(1, t / (fromWidget ? 0.08 : 0.3))   // 小工具：第一格就換成白卡（官方 v1 0:47.075），縮回來時最後一格換回小工具
                if card < 1, !fromWidget { Shell.drawAppIcon(g, face: self, icon: app.icon, in: r, appID: app.id) }   // 小工具底下本來就是小工具
                g.setAlpha((HPMotion.reduceMotion ? fade : 1) * card)
                g.setFillColor(HPTokens.bg.cgColor); g.fill(r)
                g.setAlpha(fade)
                drawUpright(g, page, in: r)
                g.restoreGState()
            }
        } else {
            drawShellBase(g, now, screen: Shell.nav.screen)
            if let a = Shell.currentApp, a.showsCloseButton || PersonalGate.locks(a.id) { drawShellNav(g, a) }
            HPGlass.flush(g, face: self, now: now)
            if let a = Shell.currentApp, a.showsClock { drawShellClock(g) }
        }
        drawShellPill(g, now)
    }

    private func drawShellBase(_ g: CGContext, _ now: Double, screen: ShellScreen) {
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        switch screen {
        case .home: drawHome(g, now, library: false)
        case .library: drawHome(g, now, library: true)
        case .app(let id): if let a = AppRegistry.app(id) { renderShellApp(a, g, full, now) }
        case .face: break
        }
    }

    // MARK: 主畫面

    /// 桌布：色相 h 的三段漸層（左上亮、右下深）＋一塊柔光，256 px 畫好放大
    func shellWallpaper() -> CGImage {   // 2.0 SpringBoard 也用
        // 2.0 R3：剛才錶面的畫面（模糊＋壓暗）；沒有才用下面的漸層
        if let b = Shell.homeBackdrop { return b }
        let h = Shell.homeHue ?? Shell.hue(fromFace: nil, face: self)
        let key = String(format: "%.3f", h)
        if let w = Shell.wallpaper, w.key == key { return w.image }
        func hsb(_ dh: CGFloat, _ s: CGFloat, _ b: CGFloat) -> CGColor {
            var x = (h + dh).truncatingRemainder(dividingBy: 1); if x < 0 { x += 1 }
            return NSColor(hue: x, saturation: s, brightness: b, alpha: 1).cgColor
        }
        let img = makeImage(256, 256) { g in
            g.scaleBy(x: 0.25, y: 0.25)
            let cs = CGColorSpace(name: CGColorSpace.sRGB)
            let grad = CGGradient(colorsSpace: cs, colors: [hsb(-0.025, 0.50, 1.0), hsb(0, 0.70, 0.89), hsb(0.045, 0.74, 0.56)] as CFArray,
                                  locations: [0, 0.45, 1])!
            g.drawLinearGradient(grad, start: CGPoint(x: 180, y: 0), end: CGPoint(x: 844, y: 1024), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            let blob = CGGradient(colorsSpace: cs, colors: [hsb(-0.06, 0.40, 1.0), hsb(-0.06, 0.40, 1.0).copy(alpha: 0)!] as CFArray, locations: [0, 1])!
            g.setAlpha(0.55)
            g.drawRadialGradient(blob, startCenter: CGPoint(x: 860, y: 140), startRadius: 0, endCenter: CGPoint(x: 860, y: 140), endRadius: 520, options: [])
            g.drawRadialGradient(blob, startCenter: CGPoint(x: 120, y: 980), startRadius: 0, endCenter: CGPoint(x: 120, y: 980), endRadius: 380, options: [])
        }
        let ci = CIImage(cgImage: img)
        let out = Face.ciContext.createCGImage(ci.clampedToExtent().applyingGaussianBlur(sigma: 6).cropped(to: ci.extent), from: ci.extent) ?? img
        Shell.wallpaper = (key, out)
        return out
    }

    /// 靜態層（桌布＋小工具玻璃＋圖示＋標籤＋頁點）：色相、語言、解析度不變就重用
    private func homeStaticLayer(library: Bool) -> CGImage {
        let sc = renderPixelScale
        let wall = shellWallpaper()
        let day = Shell.homeDayKey(Face.displayDate)   // 第五輪 C：行事曆圖示畫的是今天；換日就整層重畫
        Shell.homeDrawnDay = day
        let look = HomeAppearance.current   // P02：主畫面外觀、這個人的排列、編輯模式都進 key
        let key = "\(library)|\(ObjectIdentifier(wall).hashValue)|\(Typo.language)|\(Int(sc * 100))|\(FaceStyle.lineup.count)|\(day)|\(look.cacheKey)|\(library ? "" : PersonHome.current.fingerprint)"
        if let c = Shell.homeLayer, c.key == key { return c.image }
        let px = Int((1024 * sc).rounded())
        let items = library ? Shell.libraryItems() : Shell.homeItems()
        let img = makeImage(px, px) { g in
            g.scaleBy(x: sc, y: sc)
            let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
            drawUpright(g, wall, in: full)
            if look.wallpaperShade > 0 { g.setFillColor(NSColor(white: 0, alpha: look.wallpaperShade).cgColor); g.fill(full) }   // P02：深色／染色外觀壓暗桌布
            let wallShot = look.glassBase ? g.makeImage() : nil   // P02：清透／染色的圖示玻璃取樣面板之前的桌布（玻璃不取樣玻璃）
            // 2.0 R3：內縮 14 px 的玻璃面板（影片 v2 00:11.5：面板邊一道細亮邊），圓角跟螢幕同心
            let inset = HPTokens.Home.panelInset
            let panelPath = continuousRoundedRect(full.insetBy(dx: inset, dy: inset), radius: Screen.concentric(inset: inset))
            HPGlass.add(panelPath) { _ in }
            HPGlass.flush(g, face: self, clear: true)   // 模糊的錶面＝媒體上：Clear
            // 第五輪：系統的 Clear 把整面提亮約 25%，官方的面板只比外面亮 7%（152 對 142）：面板裡壓回去，再畫厚玻璃的亮邊
            g.saveGState(); g.addPath(panelPath); g.setFillColor(NSColor(white: 0, alpha: HPTokens.Home.panelShade).cgColor); g.fillPath(); g.restoreGState()
            HPGlass.panelRim(g, panelPath)              // 厚玻璃的亮邊（官方邊上 +64、往內 24 px 漸回）
            Shell.drawAccentedGlassBases(g, face: self, items: items, backdrop: wallShot)   // P02：清透／染色＝圖示與小工具的底換成 Liquid Glass
            // 小工具：iOS 的液態玻璃 Regular（一個容器、一起算；2.0 iosglass：原本自拼 NSGlassEffectView .clear 的參數）
            let widgets = items.filter { if case .app = $0.1 { return false }; return true }.map(\.0)
            if !widgets.isEmpty, library {
                HPGlass.drawNow(g, face: self, widgets.map { continuousRoundedRect($0, radius: Shell.widgetRadius) }, clear: false, container: "home.widgets")
            }
            // 第五輪：圖示標籤 regular 30、白、沒有投影（官方直筆畫 2 px、字外沒有暗暈）
            let lf = HPType.sf(HPType.Size.iconLabel, HPTokens.Home.iconLabelWeight)
            let lb = HPTokens.Home.labelBaseline
            for (r, item) in items {
                guard let s = HomeWidgetKind.from(item)?.title else { continue }   // P02：小工具標籤照這格放的是哪一個
                drawLeft(g, s, font: lf, x: r.midX - Typo.width(s, lf) / 2, y: r.maxY + lb, color: .white)
            }
            for (r, item) in items {
                guard case .app(let id) = item, let app = AppRegistry.app(id) else { continue }
                let ir = Shell.iconRect(in: r)
                Shell.drawHomeIcon(g, face: self, app: app, in: ir)   // P02：照主畫面外觀出圖示變體（Shell/HomeWidgets.swift）
                let s = Face.clipped(app.title, lf, r.width + Shell.colGap - 6)
                drawLeft(g, s, font: lf, x: r.midX - Typo.width(s, lf) / 2, y: ir.maxY + lb, color: .white)
            }
            // 2.0 R4：影片裡沒有頁點（錶面之間照樣可以滑）
        }
        Shell.homeLayer = (key, img)
        return img
    }

    private func drawHome(_ g: CGContext, _ now: Double, library: Bool) {
        if Shell.homeHue == nil { Shell.homeHue = Shell.hue(fromFace: nil, face: self) }
        drawSpringBoard(g, now, library: library)   // 2.0 SpringBoard：主畫面與 App 資料庫改由 Shell/SpringBoard/SBRender.swift 畫（P02 的靜態層留著不用）
    }

    private func drawHomeP02(_ g: CGContext, _ now: Double, library: Bool) {
        _ = shellWallpaper()
        drawUpright(g, homeStaticLayer(library: library), in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        // 2.0 R4：左上全大寫問候語（影片 v1 0:45「GOOD MORNING, / MARGOT」：medium、字距放寬、白 80%），跟第一欄圖示左緣對齊
        if !library, !Shell.homeEditing {   // P02：編輯模式時左上換成「＋」
            // 第五輪：第一行 regular 32 白 60%、名字那行 semibold 32 白 82%；原點比圖示左緣內縮 9（官方主畫面）
            let H = HPTokens.Home.self
            let sx = Shell.iconRect(in: Shell.cell(0, 0)).minX + H.greetingInset
            for (i, line) in Shell.greeting(hour: Shell.greetingHour(self)).enumerated() {
                let isName = i > 0
                let sf = HPType.sf(H.greetingSize, isName ? H.nameWeight : H.greetingWeight)
                drawLeft(g, Face.clipped(line, sf, 660), font: sf, x: sx, y: H.greetingBaseline + CGFloat(i) * H.greetingLeading,
                         color: NSColor.white.withAlphaComponent((isName ? H.nameAlpha : H.greetingAlpha) * LiveActivityStack.greetingAlpha(now)), kern: H.greetingKern)   // P03：大卡展開時淡出
            }
        }
        if library || !Shell.homeEditing { drawShellAvatar(g) }   // 2.0: 誰在看（Shell/PersonalGate.swift）；P02：編輯模式時右上是「完成」
        if !library { drawHomeWidgets(g, now) }
    }

    private func drawHomeWidgets(_ g: CGContext, _ now: Double) {
        // 第六輪：照官方，右上是「照片」小工具（Shell/PhotosWidget.swift）；P02：照這個人的排列放（天氣、世界時鐘、或不放），編輯模式疊上「−」「＋」「完成」
        let layout = PersonHome.current
        if let w = layout.widget { drawHomeWidget(g, w, Shell.widgetRect(col: 2, row: 0), now: now) }
        drawHomeEditChrome(g, items: layout.items())
    }

    /// 2.0 R1：左上 88 px 玻璃圓鈕（影片 v1 0:47 行事曆、0:52 食譜：✕；子頁 ‹），系統玻璃（GlassPass，render 尾端一起算）
    func drawShellNav(_ g: CGContext, _ a: PetApp) {
        HPComponents.shellBackButton(self, symbol: PersonalGate.locks(a.id) ? "xmark" : a.backSymbol)
    }
    /// 右上：小字時間（實機的 App 裡右上只有時間；媒體全螢幕的 App 自己關掉）
    func drawShellClock(_ g: CGContext) {
        HPComponents.topClock(g, self, size: 32, baselineDY: 11, color: HPTokens.label)
    }

    /// 接管：舊畫面以中心放大 5%、從清楚化到模糊 20 px、淡出（臨界阻尼 0.5 s）；減少動態效果時只淡出
    private func drawTakeover(_ g: CGContext, _ now: Double) {
        guard let t = Shell.takeover else { Shell.takeoverNew = nil; return }
        // 動效包：兩段（v2 0:31.80→32.30）——舊畫面先放大 5%＋模糊（0.2 s），再交叉淡化；新畫面同時從模糊變清楚
        let p = max(0, min(1, t.anim.value(now)))
        let zoom = HPMotion.progress(HPMotion.T.takeoverZoom, t.anim.elapsed(now) + CGFloat(t.anim.delay))
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        if !HPMotion.reduceMotion {
            if Shell.takeoverNew == nil, let shot = g.makeImage() {
                let ci = CIImage(cgImage: shot)
                Shell.takeoverNew = Face.ciContext.createCGImage(ci.clampedToExtent().applyingGaussianBlur(sigma: Double(shot.width) / 1024 * 10).cropped(to: ci.extent), from: ci.extent)
            }
            if let nb = Shell.takeoverNew, p < 0.999 { g.saveGState(); g.setAlpha(1 - p); drawUpright(g, nb, in: full); g.restoreGState() }
        }
        g.saveGState()
        if !HPMotion.reduceMotion {
            let k = 1 + 0.05 * zoom
            g.translateBy(x: 512, y: 512); g.scaleBy(x: k, y: k); g.translateBy(x: -512, y: -512)
        }
        let fade = 1 - p
        let fog = HPMotion.reduceMotion ? 0 : zoom
        g.setAlpha(fade * (1 - fog)); drawUpright(g, t.sharp, in: full)
        g.setAlpha(fade * fog); drawUpright(g, t.blurred, in: full)
        g.restoreGState()
    }

    // MARK: 頂端藥丸（Live Activities）

    /// from：從錶面上的眼睛膠囊（rect）長過來，e＝進度（ClioTalk 打開時用）
    func drawShellPill(_ g: CGContext, _ now: Double, from: (rect: CGRect, e: CGFloat)? = nil) {
        let t = from == nil ? Shell.pillT : 0
        // 2.0 P03：先照這一幀的活動排好 compact／minimal（pillRect 照它長大）
        var acts = t > 0.02 ? shellActivities(now) : []
        for i in acts.indices { acts[i].accent = Shell.nightTint(acts[i].accent, self) }   // 第四輪：夜間的 Live Activity 也是紅的
        if !acts.isEmpty { LiveActivityStack.compactPill = laLayout(acts).pill }
        var r = Shell.pillRect(t)
        var k: CGFloat = 0.5   // 眼睛大小（drawEye 的 k；錶面上的膠囊是 1.4×scale）；P03：長成活動時眼睛不變大
        if let f = from {
            r = Shell.lerp(f.rect, r, f.e)
            k = (f.rect.height / 156) + (k - f.rect.height / 156) * f.e
        } else if let pf = Shell.pillFrom {
            // 從錶面上的眼睛膠囊縮過來
            let e = ClioTalkPanel.progress(Shell.pillSpring, CGFloat(now - pf.start))   // 2.0 R14：彈簧
            r = Shell.lerp(pf.rect, r, e)
            k = (pf.rect.height / 156) + (k - pf.rect.height / 156) * e
        }
        if t > 0.02 {
            drawActivityStack(g, r, t: t, acts: acts, now: now)   // 2.0 P03：compact／minimal／expanded（Shell/LiveActivityStack.swift）
        } else {
            LiveActivityStack.hits = []; LiveActivityStack.shown = []
            drawCapsuleBody(g, r, look: capsuleLook() == .system ? .black : capsuleLook(), animating: Shell.pillFrom != nil)
        }
        // P03：眼睛＝鏡頭，長成活動時留在正中、上緣不動（展開時也一樣，大卡從兩側與下方包住它）
        let ex = r.midX + (512 - r.midX) * t
        let ey = t > 0.02 ? r.minY + LiveActivityStack.height / 2 : r.midY
        let bf = blinkFactor(now)
        for s: CGFloat in [-1, 1] { drawEye(g, cx: ex + s * cur.sep * k, cy: ey, side: s, blinkF: bf, k: k) }
        // 第四輪：夜間整面轉紅時只把眼睛那一段貼回原樣（Live Activity 的內容、分離的小藥丸、大卡一起變紅）
        Shell.nightKeep = t > 0.02 ? CGRect(x: ex - laEyesHalf - 6, y: r.minY, width: 2 * laEyesHalf + 12, height: LiveActivityStack.height) : nil
        LiveActivityStack.homeKeep = t > 0.02 ? LiveActivityStack.eyesPath(cx: ex, cy: ey, sep: cur.sep * k, rx: cur.rx * k, ry: cur.ry * k) : nil
        let eyes = r.insetBy(dx: -12, dy: -10)
        islandRectBuilding = islandRectBuilding.map { $0.union(eyes) } ?? eyes
    }

    // MARK: 疊在最上面的：亮度、控制中心、ClioTalk（render 在錶面／外殼畫完後叫）

    func drawShellOverlays(_ g: CGContext, _ now: Double) {
        if !shellCoversFace || Shell.nav.screen == .home { drawNightFace(g) }   // 2.0 R12／第四輪：暗處錶面與主畫面（小工具、Live Activity）黑底紅線稿（Faces/NightFace.swift）
        drawTakeover(g, now)                        // 2.0 R11：接管的舊畫面放大、模糊、淡出
        if Shell.ccT > 0.001 { ControlCenter.draw(g, face: self, now: now) }
        drawPeopleSheet(g)   // 2.0: 「換人」（ClioTalk 那一層由 ClioTalkPanel 自己畫）
        if Shell.brightness < 0.999 {
            g.setFillColor(NSColor.black.withAlphaComponent((1 - Shell.brightness) * 0.85).cgColor)
            g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        }
    }
}
