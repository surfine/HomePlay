// 2.0：頂端把手（2026-11-12 定案，docs/plans/capsule.md）。
//
// 外殼畫面（主畫面、App、資料庫、切換器、CarPlay）待機時頂端中間不再畫 👀 膠囊，改成一條預設隱藏的細把手。
// 這個檔案只管把手「長怎樣、什麼時候看得見」；手勢的判定與歸屬照舊在 Shell/HomeIndicator.swift，門檻一條都沒動。
// - 外形：寬 166、高 8、圓頭，上緣離螢幕頂 24（1024 畫布）；所有外殼畫面同一個位置，CarPlay 上也在安全帶內。
// - 顯示：換畫面後 2 秒；游標進入頂端中間的命中區、手指碰到命中區、下拉全程都顯示；沒有互動 2 秒後 250 ms 淡出。
//   只動不透明度；減少動態效果時直接切換。輔助使用「一律顯示把手」打開時不淡出。
// - 顏色：深色底白 60%、淺色底黑 35%（看把手底下那一塊畫面的亮度）。
// - 點一下：Home 鍵；只有 CarPlay 畫面上隱藏時第一下只現身。下拉、拉住停、長按不必先看到把手。
// 快照：--handle shown|hidden（--screen-png／--snapshot／--frames 沒指定時＝hidden，也就是淡出之後的樣子）。

import AppKit

enum HomeHandle {
    // MARK: 外形（1024 畫布 px）

    static let width: CGFloat = 166
    static let height: CGFloat = 8
    static let top: CGFloat = 24
    static let rect = CGRect(x: 512 - width / 2, y: top, width: width, height: height)
    /// 點一下算 Home 鍵的範圍：把手左右各 10，從螢幕頂到 122（原本待機膠囊補到 88 高的下緣）。
    /// 下拉與長按的命中區比這個大（HomeIndicator.owner 的頂端中間那一塊），那裡其餘的點按照舊交給頁面
    static let tapZone = CGRect(x: rect.minX - 10, y: 0, width: width + 20, height: 122)
    /// VoiceOver 元件與鍵盤焦點框的框
    static let focusRect = rect.insetBy(dx: -10, dy: -16)

    // MARK: 顯示規則（純邏輯，--selftest 直接驗）

    /// 最後一次互動之後還顯示多久；淡入淡出多長（秒）
    static let linger: Double = 2
    static let fade: Double = 0.25

    struct Visibility: Equatable {
        /// 這個時間點之前算「看得見」（最後一次互動＋linger）
        var shownUntil = -Double.infinity
        /// 淡入的起點（已經換算成「從全透明開始」的時間）
        var fadeInFrom = -Double.infinity

        func isShown(now: Double) -> Bool { now < shownUntil }
        /// 線性的不透明度 0…1（顯示時再套緩出）
        func level(now: Double, reduceMotion: Bool) -> Double {
            if reduceMotion { return isShown(now: now) ? 1 : 0 }
            let fadeIn = (now - fadeInFrom) / HomeHandle.fade
            let fadeOut = 1 - (now - shownUntil) / HomeHandle.fade
            return max(0, min(1, min(fadeIn, fadeOut)))
        }
        /// 有互動（換畫面、游標進來、手指碰到、正在拉）：從現在的不透明度接著淡入，再顯示 linger 秒
        mutating func reveal(now: Double, reduceMotion: Bool) {
            let a = level(now: now, reduceMotion: reduceMotion)
            if a < 1 { fadeInFrom = now - a * HomeHandle.fade }
            shownUntil = now + HomeHandle.linger
        }
    }

    /// 點在把手上＝Home 鍵，一次往上一層：App／資料庫／切換器 → 主畫面 → 表面。
    /// 只有 CarPlay 直播畫面上、把手還看不見時，第一下只讓它現身
    /// （2026-11-13 定案：那裡頂端的點按可能是要給 iPhone 的，其他畫面頂端中間沒有別的東西，不必多點一下）
    enum Tap: Equatable { case reveal, home, surface }
    static func tap(shownAtDown: Bool, livePill: Bool, onCarPlay: Bool, screen: ShellScreen) -> Tap {
        if onCarPlay { return !shownAtDown && !livePill ? .reveal : .home }
        if screen == .home { return .surface }   // 主畫面的再上一層就是表面（2026-11-18 拍板）
        return .home
    }

    /// 深色底用白、淺色底用黑；在門檻附近不來回跳（遲滯）
    static func isDark(luminance: CGFloat, was: Bool) -> Bool { luminance < (was ? 0.62 : 0.5) }
    static func color(dark: Bool) -> NSColor { dark ? NSColor(white: 1, alpha: 0.6) : NSColor(white: 0, alpha: 0.35) }

    // MARK: 下拉越過界線：全亮（2026-11-13）
    // 震動只有力度觸控板有；Magic Mouse 與一般滑鼠靠這個看得見的回饋（HIG Playing haptics：震動搭配其他回饋）。
    // 把手在下拉全程固定畫在頂端；拉過「放開就回主畫面」的那一點從半透明變成全亮，退回界線內變回來。只動不透明度。

    /// 全亮的淡入淡出多長（秒）；減少動態效果時直接切換
    static let litFade: Double = 0.12
    struct Lit: Equatable {
        var on = false
        var changedAt = -Double.infinity
        /// 0＝平常的半透明、1＝全亮
        func level(now: Double, reduceMotion: Bool) -> Double {
            if reduceMotion { return on ? 1 : 0 }
            let k = max(0, min(1, (now - changedAt) / HomeHandle.litFade))
            return on ? k : 1 - k
        }
        mutating func set(_ v: Bool, now: Double, reduceMotion: Bool) {
            guard v != on else { return }
            let cur = level(now: now, reduceMotion: reduceMotion)
            on = v
            changedAt = now - (v ? cur : 1 - cur) * HomeHandle.litFade   // 半路反向：從當下的亮度接著走
        }
    }
    /// 這一格把手的不透明度：平常的顏色（白 60%／黑 35%）到全亮（100%）
    static func pullAlpha(dark: Bool, level: Double) -> CGFloat {
        let base = color(dark: dark).alphaComponent
        return base + (1 - base) * CGFloat(level)
    }
    nonisolated(unsafe) static var lit = Lit()
    /// 下拉起手時重拍一格當卡片：那一格不畫把手（把手固定畫在頂端，不跟著卡片往下走）
    nonisolated(unsafe) static var suppressed = false

    /// 下拉中（HomeIndicator.renderIndicatorPull）：把手固定在頂端。past＝已經越過界線
    static func drawPulling(_ g: CGContext, past: Bool, now: Double) {
        lit.set(past, now: now, reduceMotion: HPMotion.reduceMotion)
        let dark = resolveDark(backdrop: g.makeImage())
        let a = pullAlpha(dark: dark, level: lit.level(now: now, reduceMotion: HPMotion.reduceMotion))
        g.saveGState()
        g.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil))
        g.setFillColor(color(dark: dark).withAlphaComponent(a).cgColor); g.fillPath()
        g.restoreGState()
    }

    // MARK: 設定（設定 › 輔助使用）

    static let alwaysKey = "screenAlwaysShowHandle"
    static var alwaysShow: Bool {
        get { UserDefaults.standard.bool(forKey: alwaysKey) }
        set { UserDefaults.standard.set(newValue, forKey: alwaysKey); HPAccessibilitySettings.changed() }
    }

    // MARK: 狀態

    nonisolated(unsafe) static var visibility = Visibility()
    /// 游標在頂端中間的命中區裡（PetView.mouseMoved）
    nonisolated(unsafe) static var hover = false
    /// 按下那一刻把手看不看得見（放手時決定這一下是現身還是 Home 鍵）
    nonisolated(unsafe) static var shownAtDown = false
    nonisolated(unsafe) private static var surfaceKey = ""
    nonisolated(unsafe) private static var wasDark = true
    /// 最近一次畫出來的不透明度（外殼這一幀；不一樣就要重畫）
    nonisolated(unsafe) static var drawnAlpha: CGFloat = -1

    /// 快照：--handle shown|hidden；出圖的路沒指定＝hidden
    static let forced: Bool? = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--handle"), i + 1 < a.count {
            switch a[i + 1] { case "shown": return true; case "hidden": return false; default: return nil }
        }
        return ["--screen-png", "--snapshot", "--frames"].contains { a.contains($0) } ? false : nil
    }()

    static func isShown(now: Double) -> Bool { forced ?? (alwaysShow || visibility.isShown(now: now)) }

    /// 這一刻的不透明度 0…1
    static func alpha(now: Double) -> CGFloat {
        if let forced { return forced ? 1 : 0 }
        if alwaysShow { return 1 }
        let x = visibility.level(now: now, reduceMotion: HPMotion.reduceMotion)
        return CGFloat(1 - (1 - x) * (1 - x))   // 緩出
    }

    static func reveal(now: Double) { visibility.reveal(now: now, reduceMotion: HPMotion.reduceMotion) }

    /// 按在命中區上：先記下這一刻看不看得見，再讓它現身
    static func pressBegan(now: Double) {
        shownAtDown = isShown(now: now)
        reveal(now: now)
    }

    /// 每幀（PetView.shellStep）：surface＝現在是哪個畫面（換了就顯示 2 秒；錶面上沒有把手）；held＝游標在命中區、手指按著、正在拉
    static func step(now: Double, surface: String, onShell: Bool, held: Bool) {
        if surface != surfaceKey {
            surfaceKey = surface
            if onShell { reveal(now: now) }
        }
        if held, onShell { reveal(now: now) }
    }

    // MARK: 畫

    /// 把手底下那一塊畫面的平均亮度（img＝這一幀已經畫好的畫面，rect＝1024 畫布座標）
    static func luminance(of img: CGImage, in rect: CGRect) -> CGFloat? {
        let sc = CGFloat(img.width) / 1024
        let r = CGRect(x: rect.minX * sc, y: rect.minY * sc, width: rect.width * sc, height: rect.height * sc).integral
        guard let crop = img.cropping(to: r) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let c = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.interpolationQuality = .medium
            c.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard ok else { return nil }
        return (0.2126 * CGFloat(px[0]) + 0.7152 * CGFloat(px[1]) + 0.0722 * CGFloat(px[2])) / 255
    }

    /// 這一幀該用白還是黑（backdrop＝把手底下的畫面；拿不到就沿用上一次）
    static func resolveDark(backdrop: CGImage?) -> Bool {
        if let backdrop, let l = luminance(of: backdrop, in: rect.insetBy(dx: -4, dy: -4)) { wasDark = isDark(luminance: l, was: wasDark) }
        return wasDark
    }

    static func fill(_ g: CGContext, _ r: CGRect, dark: Bool, alpha: CGFloat) {
        guard alpha > 0.003 else { return }
        g.saveGState()
        g.setAlpha(alpha)
        g.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil))
        g.setFillColor(color(dark: dark).cgColor); g.fillPath()
        g.restoreGState()
    }
}

// MARK: - 自檢

enum HomeHandleSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        typealias H = HomeHandle
        // 外形與位置：同一條、在 CarPlay 安全帶內、在主畫面的玻璃面板裡
        let band = HomeIndicator.bandHeight(inset: 80)
        check(H.rect.width == 166 && H.rect.height == 8 && H.rect.minY == 24 && H.rect.midX == 512, "把手：寬 166、高 8、上緣離頂 24、置中")   // l10n-ignore
        check(H.rect.minY > 0 && H.rect.maxY <= band && HomeIndicator.carPlayHit(inset: 80).contains(H.rect), "把手：CarPlay 上整條收在安全帶內，也在歸外殼的那一塊裡")   // l10n-ignore
        check(H.rect.minY >= HPTokens.Home.panelInset + 8 && H.rect.maxY < Shell.pillSlot.maxY, "把手：在主畫面的玻璃面板裡（上緣至少留 8），不低過即時動態的藥丸槽")   // l10n-ignore
        check(H.tapZone.contains(H.rect) && HomeIndicator.owner(CGPoint(x: H.tapZone.midX, y: H.tapZone.maxY - 1), on: .app, pill: nil, inset: nil) == .indicator,
              "把手：點按範圍包住把手，而且整塊都在下拉的命中區裡")   // l10n-ignore
        // 顯示規則
        var v = H.Visibility()
        check(!v.isShown(now: 0) && v.level(now: 0, reduceMotion: false) == 0, "把手：預設隱藏")   // l10n-ignore
        v.reveal(now: 10, reduceMotion: false)
        check(v.isShown(now: 10) && v.level(now: 10, reduceMotion: false) == 0 && v.level(now: 10 + H.fade, reduceMotion: false) == 1
              && v.level(now: 11.9, reduceMotion: false) == 1, "把手：換畫面後淡入，顯示 2 秒")   // l10n-ignore
        check(!v.isShown(now: 12) && abs(v.level(now: 12 + H.fade / 2, reduceMotion: false) - 0.5) < 1e-9 && v.level(now: 12 + H.fade, reduceMotion: false) == 0,
              "把手：2 秒後用 250 毫秒淡出")   // l10n-ignore
        var held = v
        for i in 0..<50 { held.reveal(now: 10 + Double(i) * 0.1, reduceMotion: false) }   // 游標停在命中區／拉著：每幀續命
        check(held.level(now: 14.9, reduceMotion: false) == 1 && held.isShown(now: 16.8) && !held.isShown(now: 17), "把手：互動中不淡出，最後一次互動再過 2 秒才收")   // l10n-ignore
        var again = v
        again.reveal(now: 12 + H.fade / 2, reduceMotion: false)   // 淡出到一半又碰到
        check(abs(again.level(now: 12 + H.fade / 2, reduceMotion: false) - 0.5) < 1e-9 && again.level(now: 12 + H.fade, reduceMotion: false) == 1,
              "把手：淡出到一半又互動，從當下的不透明度接著淡入（不跳）")   // l10n-ignore
        var rm = H.Visibility()
        rm.reveal(now: 10, reduceMotion: true)
        check(rm.level(now: 10, reduceMotion: true) == 1 && rm.level(now: 11.99, reduceMotion: true) == 1 && rm.level(now: 12.01, reduceMotion: true) == 0,
              "把手：減少動態效果時直接切換，不淡入淡出")   // l10n-ignore
        // 點一下＝往上一層：App→主畫面、主畫面→表面；只有 CarPlay 畫面上、把手看不見時第一下只現身
        check(H.tap(shownAtDown: false, livePill: false, onCarPlay: true, screen: .app(CarPlayApp.id)) == .reveal
              && H.tap(shownAtDown: true, livePill: false, onCarPlay: true, screen: .app(CarPlayApp.id)) == .home
              && H.tap(shownAtDown: false, livePill: false, onCarPlay: false, screen: .app("weather")) == .home
              && H.tap(shownAtDown: false, livePill: true, onCarPlay: false, screen: .home) == .surface,
              "把手：點一下往上一層（App→主畫面、主畫面→表面）；只有 CarPlay 畫面上隱藏時第一下只現身")   // l10n-ignore
        // 隱藏時下拉、拉住停、長按照樣成立：歸屬與判定都不看把手看不看得見
        let hidden = H.Visibility()
        check(!hidden.isShown(now: 100)
              && HomeIndicator.owner(CGPoint(x: 512, y: 28), on: .app, pill: nil, inset: nil) == .indicator
              && HomeIndicator.owner(CGPoint(x: 512, y: 28), on: .home, pill: nil, inset: nil) == .indicator
              && HomeIndicator.owner(CGPoint(x: 512, y: 28), on: .carPlay, pill: nil, inset: 80) == .indicator
              && HomeIndicator.outcome(distance: 120, velocity: 0, armed: false) == .home
              && HomeIndicator.outcome(distance: 90, velocity: 0, armed: true) == .switcher
              && HomeIndicator.releaseAction(consumed: false, claimed: true, moved: true, onCarPlay: true) == .settle,
              "把手：隱藏時從頂端中間下拉仍是回主畫面、拉住停仍是切換器（主畫面、App、CarPlay）")   // l10n-ignore
        check(HomeIndicator.owner(CGPoint(x: 512, y: 28), on: .face, pill: nil, inset: nil) == .shell, "把手：錶面頂端沒有把手")   // l10n-ignore
        // 顏色跟底色，門檻附近不來回跳
        check(H.isDark(luminance: 0.1, was: false) && !H.isDark(luminance: 0.9, was: true) && H.isDark(luminance: 0.55, was: true) && !H.isDark(luminance: 0.55, was: false),
              "把手：深色底用白、淺色底用黑，門檻附近不閃")   // l10n-ignore
        check(H.color(dark: true).alphaComponent == 0.6 && H.color(dark: false).alphaComponent == 0.35 && H.color(dark: true).whiteComponent == 1 && H.color(dark: false).whiteComponent == 0,
              "把手：白 60%／黑 35%")   // l10n-ignore
        // 下拉越過界線：全亮；退回界線內變回來；只動不透明度；減少動態效果直接切換
        var lit = H.Lit()
        check(lit.level(now: 0, reduceMotion: false) == 0 && abs(H.pullAlpha(dark: true, level: 0) - 0.6) < 1e-9 && abs(H.pullAlpha(dark: false, level: 0) - 0.35) < 1e-9
              && H.pullAlpha(dark: true, level: 1) == 1 && H.pullAlpha(dark: false, level: 1) == 1, "把手：下拉沒過界線是平常的半透明，過了界線全亮")   // l10n-ignore
        lit.set(true, now: 10, reduceMotion: false)
        check(lit.level(now: 10, reduceMotion: false) == 0 && abs(lit.level(now: 10 + H.litFade / 2, reduceMotion: false) - 0.5) < 1e-9
              && abs(lit.level(now: 10 + H.litFade, reduceMotion: false) - 1) < 1e-9 && lit.level(now: 11, reduceMotion: false) == 1, "把手：越過界線用 120 毫秒變亮")   // l10n-ignore
        lit.set(false, now: 10 + H.litFade / 2, reduceMotion: false)
        check(abs(lit.level(now: 10 + H.litFade / 2, reduceMotion: false) - 0.5) < 1e-9 && abs(lit.level(now: 10 + H.litFade, reduceMotion: false)) < 1e-9 && lit.level(now: 11, reduceMotion: false) == 0,
              "把手：退回界線內變回來，半路反向不跳")   // l10n-ignore
        var litRM = H.Lit()
        litRM.set(true, now: 10, reduceMotion: true)
        check(litRM.level(now: 10, reduceMotion: true) == 1 && { litRM.set(false, now: 10.01, reduceMotion: true); return litRM.level(now: 10.01, reduceMotion: true) == 0 }(),
              "把手：減少動態效果時全亮直接切換")   // l10n-ignore
        check(HomeIndicator.commitMatters(surface: .app, screen: .app("timers")) && HomeIndicator.commitMatters(surface: .carPlay, screen: .app("carplay"))
              && HomeIndicator.commitMatters(surface: .home, screen: .library) && !HomeIndicator.commitMatters(surface: .home, screen: .home),
              "把手：已經在主畫面時那條界線沒有意義，不亮也不震")   // l10n-ignore
    }
}
