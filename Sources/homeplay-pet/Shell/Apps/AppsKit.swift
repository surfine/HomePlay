// 2.0 資料型 App（闹钟、天气、日历、提醒事项）共用的小零件：卡片、權限卡、「需要主人」鎖卡、捲動、示範旗標。
// 畫法跟計時器／世界時鐘一致：1024² 畫布、左上原點；頂端藥丸佔 y < 130、左上是關閉鈕；點按範圍 ≥ 88。
// 玻璃只在控制層（Rules.dc.html）：內容卡用 iOS 深色的分組底（#1C1C1E），不上玻璃；按鈕、分段控制才是玻璃。
// 2.0 逼真化：字一律 SF Pro（不用圓體）、iOS 深色系統色、inset grouped 清單（一組一張卡＋縮排分隔線）、iOS 26 開關。

import AppKit

enum AppUI {
    // MARK: 示範旗標（快照用，不需要任何權限）
    static let args = CommandLine.arguments
    static func flag(_ name: String) -> Bool { args.contains(name) }
    static var demoAlarms: Bool { flag("--demo-alarms") || flag("--demo-alarm-ring") || flag("--demo-alarm-edit") || flag("--demo-alarm-insert") }
    static var demoCalendar: Bool { flag("--demo-calendar") || flag("--demo-calendar-month") || flag("--demo-calendar-detail") || OfficialDemo.on }
    static var demoReminders: Bool { flag("--demo-reminders") || flag("--demo-reminders-list") || flag("--demo-reminders-completed") }
    static var demoWeather: Bool { flag("--demo-weather") }
    /// P12：快照旗標——`--demo-<app>-scroll <n>` 把捲動設成 n 單位（驗收：捲到一半出圖，看頂列底下的柔邊）
    static func scrollFlag(_ name: String) -> CGFloat? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count, let v = Double(args[i + 1]) else { return nil }
        return CGFloat(v)
    }

    // MARK: 尺寸
    static let margin: CGFloat = HPTokens.Space.margin
    static let contentW: CGFloat = HPTokens.contentWidth
    /// 往下捲動時內容被蓋住的上緣（大標題那一列底下）
    static let topEdge: CGFloat = 196

    static func hit(_ r: CGRect, _ p: CGPoint, pad: CGFloat = 8) -> Bool { r.insetBy(dx: -pad, dy: -pad).contains(p) }

    // MARK: 繪圖
    static func fillRound(_ g: CGContext, _ r: CGRect, radius: CGFloat, color: NSColor) {
        g.setFillColor(color.cgColor); g.addPath(continuousRoundedRect(r, radius: radius)); g.fillPath()
    }
    static func fillPill(_ g: CGContext, _ r: CGRect, color: NSColor) {
        g.setFillColor(color.cgColor)
        g.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)); g.fillPath()
    }
    // MARK: 系統色（2.0 r2：跟著 Theme——白天淺色、HPTokens.dark 時深色）
    static var bg: NSColor { HPTokens.bg }
    static var label: NSColor { HPTokens.label }
    static var secondary: NSColor { HPTokens.secondary }
    static var tertiary: NSColor { HPTokens.tertiary }
    static var grouped: NSColor { HPTokens.card }
    static var grouped2: NSColor { HPComponents.grouped2 }
    static var separator: NSColor { HPTokens.separator }
    static var orange: NSColor { HPTokens.orange }
    static var red: NSColor { HPTokens.red }
    static var green: NSColor { HPTokens.green }
    static var blue: NSColor { HPTokens.blue }
    static var yellow: NSColor { HPTokens.yellow }
    static var purple: NSColor { HPTokens.purple }

    // MARK: 字（SF Pro；大數字才用等寬）
    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { HPType.sf(size, weight) }
    /// 放得下就用 size，放不下就縮小（最小 size × minScale）
    static func fitted(_ s: String, size: CGFloat, weight: NSFont.Weight, maxWidth: CGFloat, minScale: CGFloat = 0.7) -> NSFont {
        HPType.fitted(s, size: size, weight: weight, maxWidth: maxWidth, minScale: minScale)
    }

    // MARK: inset grouped 清單
    static let groupRadius: CGFloat = HPTokens.Radius.group
    /// 一組一張圓角卡
    static func group(_ g: CGContext, _ r: CGRect, radius: CGFloat = groupRadius) {
        fillRound(g, r, radius: radius, color: grouped)
    }
    /// 列與列之間的 1 px 分隔線：從文字起點 x 畫到卡片右緣
    static func separator(_ g: CGContext, x: CGFloat, maxX: CGFloat, y: CGFloat) {
        g.setFillColor(separator.cgColor); g.fill(CGRect(x: x, y: y - 1, width: maxX - x, height: 2))
    }
    /// 右側 chevron（tertiary），回傳它左緣（給右邊的數字對齊）
    @discardableResult
    static func chevron(_ g: CGContext, _ face: Face, rightX: CGFloat, midY: CGFloat) -> CGFloat {
        face.drawSymbol(g, "chevron.right", in: CGRect(x: rightX - 20, y: midY - 16, width: 20, height: 32), color: tertiary, weight: .semibold)
        return rightX - 20
    }
    /// 分組上方的小標題（iOS 的 section header：secondary、semibold）
    static func header(_ g: CGContext, _ face: Face, _ s: String, x: CGFloat = margin + 36, y: CGFloat, color: NSColor = secondary) {
        left(face, g, s, font(30, .semibold), x: x, y: y, color)
    }

    // MARK: 控制
    /// iOS 26 開關：長膠囊軌道、比圓略寬的白色膠囊旋鈕
    /// key：同一顆開關（切換時旋鈕用 interactiveSpring 滑過去、軌道顏色跟著淡換；影片沒拍到開關，照 UISwitch）
    static func toggle(_ g: CGContext, _ r: CGRect, on: Bool, key: String? = nil, label: String? = nil) { HPComponents.toggle(g, r, on: on, key: key, label: label) }
    /// 分段控制：玻璃軌道、會滑的選中膠囊（HPComponents.segmented）；回傳每段的框（點按用）
    @discardableResult
    static func segmented(_ g: CGContext, _ face: Face, _ r: CGRect, _ items: [String], selected: Int, key: String = "seg") -> [CGRect] {
        let segs = HPComponents.segmented(g, face, r, items, selected: selected, size: 34, key: key)
        return segs.map { $0.insetBy(dx: -6, dy: -6) }
    }
    /// 圓形符號按鈕：玻璃圓（tint 給了就是 App 色染色的圓，符號用 glyph 色）
    static func circleButton(_ g: CGContext, _ face: Face, _ r: CGRect, symbol: String, glyph: NSColor? = nil, tint: NSColor? = nil) {
        HPComponents.glassCircle(g, face, r, symbol: symbol, ink: glyph ?? label, scale: 0.36, tint: tint)
    }

    static func left(_ face: Face, _ g: CGContext, _ s: String, _ font: NSFont, x: CGFloat, y: CGFloat, _ color: NSColor) {
        face.drawLeft(g, s, font: font, x: x, y: y, color: color)
    }
    static func right(_ face: Face, _ g: CGContext, _ s: String, _ font: NSFont, rightX: CGFloat, y: CGFloat, _ color: NSColor) {
        face.drawLeft(g, s, font: font, x: rightX - Typo.width(s, font), y: y, color: color)
    }
    static func center(_ face: Face, _ g: CGContext, _ s: String, _ font: NSFont, cx: CGFloat, y: CGFloat, _ color: NSColor) {
        face.drawLeft(g, s, font: font, x: cx - Typo.width(s, font) / 2, y: y, color: color)
    }
    /// 一顆文字按鈕（膠囊），回傳它的框。fill＝nil 是玻璃膠囊（一般按鈕）；給 App 色就是主要動作（實心、白字）
    @discardableResult
    static func button(_ g: CGContext, _ face: Face, _ r: CGRect, _ s: String, fill: NSColor? = nil, ink: NSColor? = nil, size: CGFloat = 38) -> CGRect {
        let ink = ink ?? (fill == nil ? label : .white)
        HPAX.note(g, r, .button, s)   // 2.0 P05
        HPComponents.glassCapsule(g, r, tint: fill) { c in
            let f = fitted(s, size: size, weight: .semibold, maxWidth: r.width - 48)
            center(face, c, s, f, cx: r.midX, y: r.midY + f.pointSize * 0.36, ink)
        }
        return r
    }
    /// 大標題（2.0 r2 R1）：目前頁的名稱，畫在左上返回圓鈕旁（HPTokens.titleX／titleBaseline）
    static func title(_ g: CGContext, _ face: Face, _ s: String) { HPComponents.bigTitle(g, face, s) }
    /// 分區標題（左對齊，SF Pro bold）
    static func sectionTitle(_ g: CGContext, _ face: Face, _ s: String, y: CGFloat, color: NSColor? = nil) {
        left(face, g, s, fitted(s, size: 40, weight: .bold, maxWidth: contentW), x: margin + 8, y: y, color ?? label)
    }

    // MARK: 個人內容的門
    /// 開了「認出誰在看」而眼前不是主人：個人內容（行程、提醒）換成鎖卡
    static var personalLocked: Bool { WhoIsLooking.recognitionEnabled && !WhoIsLooking.shared.personalContentAllowed }

    static func drawLock(_ g: CGContext, _ face: Face, title t: String) {
        let r = CGRect(x: 112, y: 230, width: 800, height: 460)
        group(g, r, radius: Screen.concentric(inset: 112))
        let c = CGRect(x: 512 - 70, y: 290, width: 140, height: 140)
        g.setFillColor(grouped2.cgColor); g.fillEllipse(in: c)
        face.drawSymbol(g, "lock.fill", in: c.insetBy(dx: 38, dy: 36), color: label)
        center(face, g, L("apps.locked.title", "需要主人"), font(52, .bold), cx: 512, y: 530, label)
        center(face, g, L("apps.locked.body", "认出主人之后才会显示"), font(34), cx: 512, y: 590, secondary)
        HPAX.note(g, CGRect(x: 112, y: 480, width: 800, height: 150), .text, L("apps.locked.title", "需要主人"), value: L("apps.locked.body", "认出主人之后才会显示"), shape: .rounded(24))   // 2.0 depth：VoiceOver
    }

    /// 沒有權限的說明卡；回傳按鈕的框（點了走既有的權限流程）
    static func drawPermission(_ g: CGContext, _ face: Face, appTitle: String, symbol: String, tint: NSColor,
                               headline: String, body: String, button b: String) -> CGRect {
        let r = CGRect(x: 112, y: 220, width: 800, height: 600)
        group(g, r, radius: Screen.concentric(inset: 112))
        let c = CGRect(x: 512 - 70, y: 270, width: 140, height: 140)
        g.setFillColor(tint.withAlphaComponent(0.22).cgColor); g.fillEllipse(in: c)
        face.drawSymbol(g, symbol, in: c.insetBy(dx: 36, dy: 36), color: tint)
        center(face, g, headline, fitted(headline, size: 48, weight: .bold, maxWidth: 720), cx: 512, y: 490, label)
        let bf = font(32)
        for (i, line) in Face.wrap(body, bf, 700, maxLines: 3).enumerated() {
            center(face, g, line, bf, cx: 512, y: 548 + CGFloat(i) * 42, secondary)
        }
        return button(g, face, CGRect(x: 512 - 200, y: 684, width: 400, height: 100), b, fill: tint, ink: .white)
    }
}

/// 垂直捲動（滾輪 dy 往上為正＝內容往下移，看到前面的）
struct AppScroll {
    var offset: CGFloat = 0
    mutating func scroll(_ dy: CGFloat, contentHeight: CGFloat, viewport: CGFloat) -> Bool {
        let maxOff = max(0, contentHeight - viewport)
        let n = min(maxOff, max(0, offset - dy))
        defer { offset = n }
        return n != offset
    }
    mutating func clamp(contentHeight: CGFloat, viewport: CGFloat) {
        offset = min(max(0, contentHeight - viewport), max(0, offset))
    }
}
