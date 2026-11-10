// 2.0：App 切換器與 CarPlay App（拍板 2026-11-06：CarPlay 是主畫面上的一個 App）。
//
// 切換器：膠囊往下拉住停一下打開（Shell/HomeIndicator.swift）。最近用過的 App 一張張卡片橫排，最新的在正中、舊的往右；
// 卡片內容是離開那個 App 時的最後一格（門關著的 App 不給，只畫圖示＋「需要主人」）。點卡片＝從卡片長回整面（跟主畫面點圖示同一套過場）；點空白、Esc、再拉一次膠囊＝回主畫面；
// 卡片往上滑＝從清單拿掉。CarPlay 的卡片不能滑掉——結束 CarPlay 會話只留右鍵選單（AppDelegate.switchSource 的約定）。
// CarPlay App：主畫面、App 資料庫、搜尋都找得到；打開＝圖示長成整面（內容是 CarPlay 最後一格），長完把直播叫到前面；
// 回主畫面後會話留在背景、播放不斷，頂端膠囊照舊顯示它的正在播放（音樂 App 的 Live Activity）與 CarPlay 角標。
// 快照：--switcher（打開切換器）、--demo-carplay front|background（一張假的 CarPlay 畫面，不連手機；見 CarPlayDemo）。

import AppKit

enum AppSwitcher {
    /// 卡片＝整面縮成這個比例
    static let cardScale: CGFloat = 0.56
    static let cardGap: CGFloat = 48
    static let cardTop: CGFloat = 250
    static var pitch: CGFloat { 1024 * cardScale + cardGap }
    static let maxRecents = 10
    /// 最近用過的 App（最新在前）
    /// 持久化（使用者 2026-11-08：重啟後切換器只剩一張卡滾不動）——iOS 的切換器跨重啟都在
    nonisolated(unsafe) static var recents: [String] = UserDefaults.standard.stringArray(forKey: "HomePlaySwitcherRecents") ?? [] {
        didSet { if recents != oldValue { UserDefaults.standard.set(recents, forKey: "HomePlaySwitcherRecents") } }
    }
    /// 每個 App 離開時的最後一格
    nonisolated(unsafe) static var shots: [String: CGImage] = [:]
    /// 橫向捲動（px，0＝第一張在正中）；拖著時跟手，放手停到最近的一張
    nonisolated(unsafe) static var scroll: CGFloat = 0
    nonisolated(unsafe) static var scrollAnim: MotionValue?
    /// 正在往上滑掉的那張（index、位移）
    nonisolated(unsafe) static var lift: (index: Int, dy: CGFloat)?
    nonisolated(unsafe) static var openedAt: Double = 0

    static func note(_ id: String) {
        recents.removeAll { $0 == id }
        recents.insert(id, at: 0)
        if recents.count > maxRecents { recents.removeLast(recents.count - maxRecents) }
    }
    static func remove(_ id: String) { recents.removeAll { $0 == id }; shots[id] = nil }
    /// CarPlay 會話活著（前面或背景）
    static func carPlayAlive(_ face: Face) -> Bool { CarPlayDemo.active || [.live, .background].contains(face.status) }
    /// 這一刻的卡片：CarPlay 會話活著就一定有它（沒從外殼開過也算，放在最前面），會話沒了就拿掉
    static func cards(recents r: [String], carPlayAlive: Bool, exists: (String) -> Bool) -> [String] {
        var out = r.filter { $0 == CarPlayApp.id ? carPlayAlive : exists($0) }
        if carPlayAlive, !out.contains(CarPlayApp.id) { out.insert(CarPlayApp.id, at: 0) }
        return out
    }
    static func cards(face: Face) -> [String] { cards(recents: recents, carPlayAlive: carPlayAlive(face), exists: { AppRegistry.app($0) != nil }) }

    static func open(now: Double) { scroll = 0; scrollAnim = nil; lift = nil; openedAt = now }
    /// 第 i 張卡片的框（含捲動）
    static func cardRect(_ i: Int, scroll s: CGFloat? = nil) -> CGRect {
        let w = 1024 * cardScale
        return CGRect(x: 512 - w / 2 + CGFloat(i) * pitch - (s ?? scroll), y: cardTop, width: w, height: w)
    }
    /// 放手停在哪一張（捲動量）
    static func snap(_ s: CGFloat, velocity v: CGFloat, count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let projected = s + HPMotion.project(v) * 0.4
        let i = max(0, min(CGFloat(count - 1), (projected / pitch).rounded()))
        return i * pitch
    }
    /// 卡片往上滑多遠（或多快）算拿掉
    static func dismisses(dy: CGFloat, velocity v: CGFloat) -> Bool { dy < -180 || (dy < -60 && v < -900) }
    static func canDismiss(_ id: String) -> Bool { id != CarPlayApp.id }
    /// 卡片裡畫什麼（2026-11-07）：門關著的 App（PersonalGate.locks：CarPlay、訊息…）不給最後一格——只畫圖示＋「需要主人」，
    /// 免得訪客從切換器看到主人的畫面；沒有最後一格＝底色＋大圖示
    enum CardContent: Equatable { case shot, icon, needsOwner }
    static func content(hasShot: Bool, locked: Bool) -> CardContent { locked ? .needsOwner : (hasShot ? .shot : .icon) }
}

// MARK: - CarPlay App

final class CarPlayApp: PetApp {
    static let id = "carplay"
    static let shared = CarPlayApp()
    let id = "carplay"
    var title: String { L("app.carplay", "CarPlay") }
    let icon = AppIcon(color: HPComponents.green, symbol: "car.fill")
    /// 從外殼打開（圖示、切換器）：過場走完要把直播叫到前面
    var pendingFront = false
    var showsCloseButton: Bool { false }   // 回主畫面靠膠囊，不畫左上的返回鈕
    var showsClock: Bool { false }

    /// 平常看不到這一頁（直播蓋在上面）；過場、切換器、還在連線時才畫：CarPlay 的最後一格，沒有就是黑底＋圖示
    func render(into g: CGContext, face: Face, rect: CGRect, now: Double) {
        // 沒有直播會話：一律畫 standby，不用舊快照——會話結束後的快照是黑幀，卡片整塊黑（使用者 2026-11-08 錄影實錘）
        if AppSwitcher.carPlayAlive(face), let s = AppSwitcher.shots[id] { face.drawUpright(g, s, in: rect); return }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let grad = CGGradient(colorsSpace: cs, colors: [NSColor(srgbRed: 0.10, green: 0.11, blue: 0.14, alpha: 1).cgColor,
                                                        NSColor(srgbRed: 0.04, green: 0.05, blue: 0.07, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
        let r = CGRect(x: 512 - 96, y: 360, width: 192, height: 192)
        Shell.drawAppIcon(g, face: face, icon: icon, in: r, appID: id)
        let live = AppSwitcher.carPlayAlive(face)
        let font = Face.rounded(40, weight: .semibold), ink = NSColor.white.withAlphaComponent(0.7)
        // 從沒配過 iPhone：不是「正在連接」，是先配對（主畫面第二頁的 CarPlay 第一次點下去就到這裡；連線卡與步驟照舊會出）
        if !live, CarPlayPhoneBook.phones.isEmpty {
            let lines = Face.wrap(L("setup.carplay.body", "用蓝牙配对一次，iPhone 的 App 就会用 CarPlay 显示在这里；之后靠近就会连上。"), font, 760, maxLines: 3)
            for (i, line) in lines.enumerated() { face.drawCentered(g, line, font: font, y: 620 + CGFloat(i) * 56, color: ink) }
            return
        }
        face.drawCentered(g, live ? title : L("carplay.app.connecting", "正在连接 iPhone…"), font: font, y: 620, color: ink)
    }
    func didClose() { pendingFront = false }
}

// MARK: - 假的 CarPlay 畫面（快照與逐格用，不連手機）

enum CarPlayDemo {
    /// --demo-carplay front|background|glide
    static let mode: String? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--demo-carplay") else { return nil }
        return i + 1 < a.count && !a[i + 1].hasPrefix("--") ? a[i + 1] : "front"
    }()
    static var active: Bool { mode != nil }
    /// 快照裡「CarPlay 在前面」：front／glide 模式、CarPlay App 在導覽最上層、還沒被膠囊拉下來
    static var showsVideo: Bool { (mode == "front" || mode == "glide") && Shell.nav.screen == .app(CarPlayApp.id) && !Shell.carPlayPeek && HomeIndicator.settle == nil }
    /// 快照的一格：假的 CarPlay 畫面＋疊上膠囊（跟真的直播同一張膠囊圖）；不是 CarPlay 在前面就回 nil（照常畫外殼）
    static func render(_ face: Face, now: Double) -> CGImage? {
        guard showsVideo else { return nil }
        CarPlayChrome.shared.prepareForSnapshot(face: face, now: now, backdropFrom: frame)
        return CarPlayChrome.scaled(CarPlayChrome.shared.composite(frame), to: 1024)
    }
    /// 1088² 的假畫面：外圈 80 px 只有底色（跟接收端宣告的安全區一樣），中間是 CarPlay 的主畫面樣子（圖示格、Dock）
    static let frame: CGImage = makeImage(1088, 1088) { g in
        g.setFillColor(srgb(0x1c1c1e).cgColor); g.fill(CGRect(x: 0, y: 0, width: 1088, height: 1088))
        let safe = CGRect(x: 80, y: 80, width: 928, height: 928)
        g.setFillColor(srgb(0x2c2c2e).cgColor)
        g.addPath(CGPath(roundedRect: safe, cornerWidth: 64, cornerHeight: 64, transform: nil)); g.fillPath()
        // Dock（左邊一欄）
        g.setFillColor(srgb(0x3a3a3c).cgColor)
        g.addPath(CGPath(roundedRect: CGRect(x: 104, y: 104, width: 140, height: 880), cornerWidth: 40, cornerHeight: 40, transform: nil)); g.fillPath()
        let colors: [UInt32] = [0x34c759, 0xff3b30, 0x0a84ff, 0xff9500, 0xaf52de, 0x5ac8fa, 0xffcc00, 0x30d158]
        for i in 0..<3 {
            g.setFillColor(srgb(colors[i]).cgColor)
            g.addPath(CGPath(roundedRect: CGRect(x: 124, y: 140 + CGFloat(i) * 150, width: 100, height: 100), cornerWidth: 24, cornerHeight: 24, transform: nil)); g.fillPath()
        }
        for r in 0..<2 { for c in 0..<4 {
            g.setFillColor(srgb(colors[(r * 4 + c) % colors.count]).cgColor)
            let x = 290 + CGFloat(c) * 180, y = 200 + CGFloat(r) * 330
            g.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: 150, height: 150), cornerWidth: 34, cornerHeight: 34, transform: nil)); g.fillPath()
            g.setFillColor(NSColor(white: 1, alpha: 0.55).cgColor)
            g.fill(CGRect(x: x + 25, y: y + 175, width: 100, height: 18))
        } }
    }
}

// MARK: - 畫

extension Face {
    /// 切換器整面：主畫面桌布壓暗，卡片橫排，卡片上方是圖示＋名字
    func drawSwitcher(_ g: CGContext, _ now: Double) {
        let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        drawUpright(g, shellWallpaper(), in: full)
        g.setFillColor(NSColor(white: 0, alpha: 0.35).cgColor); g.fill(full)
        if let a = AppSwitcher.scrollAnim { AppSwitcher.scroll = a.value(now); if a.done(now) { AppSwitcher.scrollAnim = nil } }
        let cards = AppSwitcher.cards(face: self)
        if cards.isEmpty {
            drawCentered(g, L("switcher.empty", "没有最近使用的 App"), font: Face.rounded(40, weight: .semibold), y: 540, color: NSColor.white.withAlphaComponent(0.7))
            return
        }
        let font = Face.rounded(30, weight: .semibold)
        let landing = HomeIndicator.settle.flatMap { $0.outcome == .switcher ? $0.appID : nil }   // 膠囊拉進來的那張還在飛：先不畫它的位置
        for (i, id) in cards.enumerated() where id != landing {
            var r = AppSwitcher.cardRect(i)
            if let l = AppSwitcher.lift, l.index == i { r = r.offsetBy(dx: 0, dy: l.dy) }
            guard r.maxX > -40, r.minX < 1064, let app = AppRegistry.app(id) else { continue }
            let radius = Screen.cornerRadius * AppSwitcher.cardScale
            let path = continuousRoundedRect(r, radius: radius)
            g.saveGState()
            g.setShadow(offset: CGSize(width: 0, height: 12), blur: 40, color: NSColor(white: 0, alpha: 0.45).cgColor)
            g.addPath(path); g.setFillColor(NSColor.black.cgColor); g.fillPath()
            g.restoreGState()
            g.saveGState(); g.addPath(path); g.clip()
            switch AppSwitcher.content(hasShot: AppSwitcher.shots[id] != nil, locked: PersonalGate.locks(id)) {
            case .shot: if let s = AppSwitcher.shots[id] { drawUpright(g, s, in: r) }
            case .icon:   // 還沒有最後一格：底色＋大圖示
                g.setFillColor(HPTokens.bg.cgColor); g.fill(r)
                Shell.drawAppIcon(g, face: self, icon: app.icon, in: CGRect(x: r.midX - 72, y: r.midY - 72, width: 144, height: 144), appID: id)
            case .needsOwner:   // 門關著：深色底＋圖示＋「需要主人」（同鎖定頁的縮小版，不露最後一格）
                g.setFillColor(srgb(0x0b0b0e).cgColor); g.fill(r)
                Shell.drawAppIcon(g, face: self, icon: app.icon, in: CGRect(x: r.midX - 72, y: r.midY - 110, width: 144, height: 144), appID: id)
                g.translateBy(x: r.midX - 512, y: 0)   // drawCentered 以畫布中線置中：移到這張卡的中線（clip 之後才移，下面就 restore）
                drawCentered(g, L("guest.needsOwner", "需要主人"), font: Face.rounded(36, weight: .bold), y: r.midY + 86, color: .white)
            }
            g.restoreGState()
            // 圖示＋名字：卡片左上方
            let ic = CGRect(x: r.minX + 4, y: r.minY - 76, width: 60, height: 60)
            Shell.drawAppIcon(g, face: self, icon: app.icon, in: ic, appID: id)
            drawLeft(g, Face.clipped(app.title, font, r.width - 90), font: font, x: ic.maxX + 16, y: ic.midY + 11, color: .white)
        }
    }
}

// MARK: - 輸入

extension PetView {
    /// 快照：--demo-carplay front|glide|background|toface、--switcher
    func applyCarPlayDemo() {
        let a = CommandLine.arguments, now = CACurrentMediaTime()
        if let m = CarPlayDemo.mode {
            if Shell.homeHue == nil { let shot = face.render(); Shell.homeHue = Shell.hue(fromFace: shot, face: face); Shell.captureHomeBackdrop(shot) }
            let pill = face.capsuleCore ?? Shell.pillRect(0)
            CarPlayChrome.shared.prepareForSnapshot(face: face, now: now, backdropFrom: CarPlayDemo.frame)
            AppSwitcher.shots[CarPlayApp.id] = CarPlayChrome.scaled(CarPlayChrome.shared.composite(CarPlayDemo.frame), to: 1024)
            switch m {
            case "background":   // 會話在背景：主畫面（頂端藥丸掛 CarPlay 角標、正在播放）
                face.status = .background
                if Shell.nav.screen == .face { Shell.nav.screen = .home }
            case "toface":   // 從 CarPlay 回錶面：膠囊從那條帶滑回錶面上的位置（HOMEPLAY_ANIM=cpglide:t）
                face.status = .background
                Shell.nav = ShellNav()
                Face.capsuleGlide = (HomeIndicator.carPlayCapsule(inset: HomeIndicator.inset), now)
            default:   // front／glide：CarPlay 在前面（glide＝膠囊從剛才的位置滑進帶裡，HOMEPLAY_ANIM=cpglide:t）
                face.status = .live
                Shell.nav = ShellNav(screen: .app(CarPlayApp.id), overlay: .none, appReturn: .home)
                CarPlayChrome.shared.glide = m == "glide" ? (pill, now) : nil
            }
        }
        if a.contains("--switcher") {
            if Shell.homeHue == nil { let shot = face.render(); Shell.homeHue = Shell.hue(fromFace: shot, face: face); Shell.captureHomeBackdrop(shot) }
            if AppSwitcher.recents.isEmpty { AppSwitcher.recents = ["timers", "music", "weather"] }
            AppSwitcher.open(now: now)
            Shell.nav = ShellNav(screen: .switcher, overlay: .none, appReturn: .home)
        }
        face.forceDirty = true
    }

    /// 切換器上的點按：點卡片打開，點空白回主畫面
    func switcherTap(_ p: CGPoint) {
        let cards = AppSwitcher.cards(face: face)
        for (i, id) in cards.enumerated() where AppSwitcher.cardRect(i).insetBy(dx: 0, dy: -80).contains(p) {
            log("switcher open \(id)")
            shellOpenApp(id, from: AppSwitcher.cardRect(i))
            return
        }
        shellNavigate(.back)
    }
    /// 切換器上的拖動（dx、dy：視窗點，往右、往下為正）：橫向捲動、往上滑掉卡片。回 true＝吃掉
    func switcherDragged(dx: CGFloat, dy: CGFloat, start: CGPoint?, claimedAxis: inout Int) -> Bool {
        let scale = 1024 / max(80, bounds.height * 0.6)   // 視窗點 → 畫布 px
        if claimedAxis == 0 {
            guard hypot(dx, dy) > ShellInput.slop else { return true }
            claimedAxis = abs(dx) >= abs(dy) ? 1 : 2
            if claimedAxis == 2, let s = start {
                let cards = AppSwitcher.cards(face: face)
                if let i = cards.indices.first(where: { AppSwitcher.cardRect($0).contains(s) }) { AppSwitcher.lift = (i, 0) } else { claimedAxis = 3 }
            }
            ShellInput.switcherScroll0 = AppSwitcher.scroll
        }
        let n = AppSwitcher.cards(face: face).count
        switch claimedAxis {
        case 1:
            var s = ShellInput.switcherScroll0 - dx * scale
            let maxS = CGFloat(max(0, n - 1)) * AppSwitcher.pitch
            if s < 0 { s = -HPMotion.rubberBand(-s, 300) } else if s > maxS { s = maxS + HPMotion.rubberBand(s - maxS, 300) }
            AppSwitcher.scroll = s; AppSwitcher.scrollAnim = nil
        case 2:
            if let l = AppSwitcher.lift { let y = dy * scale; AppSwitcher.lift = (l.index, y < 0 ? y : y * 0.2) }   // 往上 1:1，往下有阻力
        default: break
        }
        face.forceDirty = true
        return true
    }
    func switcherReleased(axis: Int, velocity v: CGFloat, now: Double) {
        let cards = AppSwitcher.cards(face: face)
        switch axis {
        case 1:
            let goal = AppSwitcher.snap(AppSwitcher.scroll, velocity: v, count: cards.count)
            AppSwitcher.scrollAnim = MotionValue("switcher", spring: HPMotion.release(velocity: v), from: AppSwitcher.scroll, to: goal, velocity: 0, now: now)
        case 2:
            if let l = AppSwitcher.lift, l.index < cards.count {
                let id = cards[l.index]
                if AppSwitcher.dismisses(dy: l.dy, velocity: v), AppSwitcher.canDismiss(id) {
                    AppSwitcher.remove(id)
                    log("switcher dismiss \(id)")
                    let left = AppSwitcher.cards(face: face).count
                    if left == 0 { shellNavigate(.back) }
                    else { AppSwitcher.scroll = min(AppSwitcher.scroll, CGFloat(left - 1) * AppSwitcher.pitch) }
                } else if !AppSwitcher.canDismiss(id), AppSwitcher.dismisses(dy: l.dy, velocity: v) {
                    log("switcher: CarPlay card stays (end the session from the menu)")
                }
            }
            AppSwitcher.lift = nil
        default: break
        }
        face.forceDirty = true
    }
}

// MARK: - 自檢

enum AppSwitcherSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        let exists: (String) -> Bool = { $0 != "gone" }
        check(AppSwitcher.cards(recents: ["timers", "music"], carPlayAlive: true, exists: exists) == [CarPlayApp.id, "timers", "music"],
              "切換器：CarPlay 會話在背景時一定有它的卡片（沒從外殼開過也算）")   // l10n-ignore
        check(AppSwitcher.cards(recents: ["timers", CarPlayApp.id, "music"], carPlayAlive: true, exists: exists) == ["timers", CarPlayApp.id, "music"],
              "切換器：CarPlay 照最近使用的順序排")   // l10n-ignore
        check(AppSwitcher.cards(recents: [CarPlayApp.id, "timers", "gone"], carPlayAlive: false, exists: exists) == ["timers"],
              "切換器：會話結束、App 不在了就沒有卡片")   // l10n-ignore
        check(!AppSwitcher.canDismiss(CarPlayApp.id) && AppSwitcher.canDismiss("timers"), "切換器：CarPlay 卡片滑不掉（結束會話只留右鍵選單）")   // l10n-ignore
        check(AppSwitcher.dismisses(dy: -200, velocity: 0) && AppSwitcher.dismisses(dy: -80, velocity: -1200) && !AppSwitcher.dismisses(dy: -80, velocity: -300),
              "切換器：往上滑夠遠或夠快才拿掉")   // l10n-ignore
        let p = AppSwitcher.pitch
        check(AppSwitcher.snap(p * 0.4, velocity: 0, count: 3) == 0 && AppSwitcher.snap(p * 0.6, velocity: 0, count: 3) == p && AppSwitcher.snap(p * 5, velocity: 0, count: 3) == 2 * p,
              "切換器：放手停在最近的一張，不超出頭尾")   // l10n-ignore
        let r0 = AppSwitcher.cardRect(0, scroll: 0)
        check(abs(r0.midX - 512) < 0.01 && r0.minY > 130, "切換器：第一張在正中，不壓到頂端膠囊")   // l10n-ignore
        // 導覽：切換器是一個畫面，返回＝主畫面；從切換器開 App，關掉回主畫面；CarPlay 畫面進來＝CarPlay App
        var n = ShellNav()
        _ = n.handle(.openSwitcher, faceIndex: 0, faceCount: 10)
        check(n.screen == .switcher && n.overlay == .none, "外殼：膠囊拉住停一下＝切換器")   // l10n-ignore
        _ = n.handle(.openApp(CarPlayApp.id), faceIndex: 0, faceCount: 10)
        check(n.screen == .app(CarPlayApp.id) && n.appReturn == .home, "外殼：切換器裡點 CarPlay＝打開 CarPlay App，回去是主畫面")   // l10n-ignore
        _ = n.handle(.openSwitcher, faceIndex: 0, faceCount: 10)
        _ = n.handle(.back, faceIndex: 0, faceCount: 10)
        check(n.screen == .home, "外殼：切換器返回＝主畫面")   // l10n-ignore
        check(n.handle(.carPlay, faceIndex: 0, faceCount: 10).handled && n.screen == .app(CarPlayApp.id), "外殼：CarPlay 畫面在前面＝CarPlay App 在前面")   // l10n-ignore
        check(AppRegistry.app(CarPlayApp.id) != nil && AppRegistry.visible.contains { $0.id == CarPlayApp.id }, "CarPlay App：主畫面、App 資料庫與搜尋找得到")   // l10n-ignore
    }
}
