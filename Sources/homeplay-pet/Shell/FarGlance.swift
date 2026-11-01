// 2.0 home-3：遠看（提案 docs/plans/homeview-native.html 原則 1：遠看一個答案，近看一個動作；官方「介面隨觀看距離調整」）。
//
// 每個 App 只交一句話（PetApp.farGlance），外殼統一畫——所有 App 的遠看長得一樣：小字標題、一行大字、一行細節、
// 有問題時一行琥珀色。沒有任何按鈕；點一下、捲一下、或人走近就回到原本的畫面。
// 什麼時候是「遠」：快照以外，人在遠處（face.reveal < 0.15）而且 8 秒沒碰；--far 快照強制。
// ongoing＝正在進行的事（計時器在跑、音樂在播、正在做菜）：遠看時不照 60 秒閒置回錶面——
// 跟 iOS StandBy 一樣，在房間另一頭也看得到廚房的計時器。

import AppKit

struct FarGlance: Equatable {
    /// 小字：在哪、是什麼（「玄關」「計時器」「下一個鬧鐘」）
    var title: String
    /// 大字：那一句話
    var headline: String
    /// 第二行（用 · 連起來）
    var details: [String] = []
    /// 琥珀色那行（沒回應、逾期）
    var alert: String? = nil
    /// 大字的顏色（nil＝主文字色）
    var accent: NSColor? = nil
    /// 大字是數字（倒數、時間、溫度）：用大號等寬數字
    var numeric = false
    /// 正在進行：遠看時不回錶面
    var ongoing = false
}

extension Shell {
    nonisolated(unsafe) static var far = false
    static let forceFar = CommandLine.arguments.contains("--far")
    static let farAfter = 8.0
    static let farReveal: CGFloat = 0.15

    /// 這一刻該不該是遠看（純函數，selftest 驗）
    static func wantsFar(forced: Bool, snapshot: Bool, reveal: CGFloat, idle: Double, hasGlance: Bool) -> Bool {
        guard hasGlance else { return false }
        return forced || (!snapshot && reveal < farReveal && idle > farAfter)
    }

    /// 遠看的畫法（整面）
    static func drawFar(_ g: CGContext, face: Face, _ m: FarGlance) {
        g.setFillColor(HPComponents.bg.cgColor); g.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let x = HPGrid.App.leading, w = HPGrid.App.trailing - x
        let tf = HPType.sf(48, .semibold)
        face.drawLeft(g, Face.clipped(m.title, tf, w), font: tf, x: x, y: 330, color: HPComponents.secondary)
        var y: CGFloat = 330
        if m.numeric {
            // 等寬數字比一般字寬：直接用等寬字量，放不下就往下縮（最小一半）
            var size: CGFloat = 220
            while size > 110, Typo.width(m.headline, FaceType.sf(size, .light, mono: true)) > w { size -= 4 }
            let nf = FaceType.sf(size, .light, mono: true)
            y += nf.pointSize * 0.95
            face.drawLeft(g, m.headline, font: nf, x: x, y: y, color: m.accent ?? HPComponents.label)
        } else {
            let hf = HPComponents.fitted(m.headline, size: 120, weight: .semibold, maxWidth: w, minScale: 0.5)
            y += 150
            face.drawLeft(g, Face.clipped(m.headline, hf, w), font: hf, x: x, y: y, color: m.accent ?? HPComponents.label)
        }
        y += 96
        if !m.details.isEmpty {
            let df = HPType.sf(64, .regular)
            face.drawLeft(g, Face.clipped(m.details.joined(separator: " · "), df, w), font: df, x: x, y: y, color: HPComponents.label)
            y += 96
        }
        if let a = m.alert {
            let af = HPType.sf(48, .semibold)
            face.drawLeft(g, Face.clipped(a, af, w), font: af, x: x, y: y, color: HPComponents.orange)
        }
        HPAX.note(g, CGRect(x: x, y: 260, width: w, height: max(100, y - 230)), .text, ([m.title, m.headline] + m.details + [m.alert].compactMap { $0 }).joined(separator: "，"), shape: .rounded(0))
    }
}

enum FarGlanceSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        check(Shell.wantsFar(forced: false, snapshot: false, reveal: 0.05, idle: 9, hasGlance: true), "遠看：人在遠處 8 秒沒碰就換成一句話")   // l10n-ignore：selftest 訊息
        check(!Shell.wantsFar(forced: false, snapshot: false, reveal: 0.05, idle: 5, hasGlance: true)
              && !Shell.wantsFar(forced: false, snapshot: false, reveal: 0.5, idle: 30, hasGlance: true), "遠看：剛碰過、人在附近都不換")   // l10n-ignore：selftest 訊息
        check(!Shell.wantsFar(forced: false, snapshot: true, reveal: 0, idle: 99, hasGlance: true)
              && Shell.wantsFar(forced: true, snapshot: true, reveal: 1, idle: 0, hasGlance: true)
              && !Shell.wantsFar(forced: true, snapshot: false, reveal: 0, idle: 99, hasGlance: false), "遠看：快照不自己換（--far 才換）；沒有遠看版的 App 不換")   // l10n-ignore：selftest 訊息
    }
}
