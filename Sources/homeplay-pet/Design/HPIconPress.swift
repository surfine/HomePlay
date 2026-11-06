// 體驗追趕 P2：按住圖示的動效——兩種可插拔的 animator，參數在 HPMotion.T.iconPress。
//
// - center：按著的那顆往中心縮、變暗一點，同一組的其他圖示一起往後退（縮一點、淡一點）——整組的焦點落在手指下。
// - crossfade：不縮放，只把按著的那顆交叉淡到變暗的樣子；減少動態效果時一律用它。
// 「同一組」＝主畫面這一頁的格子（Dock 已拍板移除，2026-11-06）。

import AppKit

struct IconPressTuning: Equatable {
    enum Animator: String { case center, crossfade }
    var animator: Animator
    /// center：按著那顆縮到多少、周圍縮到多少與淡到多少
    var pressedScale: CGFloat
    var neighborScale: CGFloat
    var neighborAlpha: CGFloat
    /// 按著那顆的壓暗（黑的不透明度；center 小一點，因為已經有縮放）
    var centerDim: CGFloat
    var crossfadeDim: CGFloat
    var down: Spring
    var up: Spring
}

enum HPIconPress {
    struct Look: Equatable {
        var scale: CGFloat = 1
        var alpha: CGFloat = 1
        var dim: CGFloat = 0
    }

    /// 純函式：k＝按壓進度 0…1
    static func look(_ t: IconPressTuning, animator: IconPressTuning.Animator, k: CGFloat, pressed: Bool) -> Look {
        let k = max(0, min(1, k))
        switch animator {
        case .center:
            return pressed ? Look(scale: 1 - (1 - t.pressedScale) * k, alpha: 1, dim: t.centerDim * k)
                           : Look(scale: 1 - (1 - t.neighborScale) * k, alpha: 1 - (1 - t.neighborAlpha) * k, dim: 0)
        case .crossfade:
            return pressed ? Look(dim: t.crossfadeDim * k) : Look()
        }
    }
    static func animator(_ t: IconPressTuning, reduceMotion: Bool) -> IconPressTuning.Animator { reduceMotion ? .crossfade : t.animator }

    // MARK: 狀態（SB.pressedKey 改變時呼叫）
    nonisolated(unsafe) private(set) static var key: String?
    nonisolated(unsafe) private static var progress: MotionValue?

    static func down(_ k: String, now: Double = CACurrentMediaTime()) {
        let from = key == k ? (progress?.value(now) ?? 0) : 0
        key = k
        progress = MotionValue("icon.press", spring: HPMotion.T.iconPress.down, from: from, to: 1, now: now)
    }
    static func up(now: Double = CACurrentMediaTime()) {
        guard var p = progress else { return }
        p.retarget(0, now: now, spring: HPMotion.T.iconPress.up)
        progress = p
    }
    static func amount(_ now: Double) -> CGFloat { progress.map { max(0, $0.value(now)) } ?? 0 }
    static func animating(_ now: Double) -> Bool {
        guard let p = progress else { return false }
        if p.to == 0, p.done(now) { progress = nil; key = nil; return false }
        return true
    }
    /// 這一幀某個項目的樣子（key＝項目的 key）
    static func look(for itemKey: String?, now: Double) -> Look {
        guard let pk = key, let ik = itemKey else { return Look() }
        let k = amount(now)
        guard k > 0.001 else { return Look() }
        let t = HPMotion.T.iconPress
        return look(t, animator: animator(t, reduceMotion: HPMotion.reduceMotion), k: k, pressed: pk == ik)
    }
}

extension HPIconPress {
    /// 快照：--home-press <項目 key>（例如 a:music）＝按住那顆；配 HOMEPLAY_ANIM=icon.press:0.3 凍結
    nonisolated(unsafe) private static var snapshotPressed = false
    static func applySnapshotPress() {
        guard !snapshotPressed else { return }
        snapshotPressed = true
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--home-press"), i + 1 < a.count { SB.pressedKey = a[i + 1] }
    }
}

enum HPIconPressSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        let t = HPMotion.T.iconPress
        let p = HPIconPress.look(t, animator: .center, k: 1, pressed: true), n = HPIconPress.look(t, animator: .center, k: 1, pressed: false)
        check(p.scale < n.scale && n.scale < 1 && n.alpha < 1 && p.dim > 0, "圖示按壓：center＝按著的縮最多、周圍退後")   // l10n-ignore
        let cp = HPIconPress.look(t, animator: .crossfade, k: 1, pressed: true), cn = HPIconPress.look(t, animator: .crossfade, k: 1, pressed: false)
        check(cp.scale == 1 && cp.dim > 0 && cn == HPIconPress.Look(), "圖示按壓：crossfade 不縮放、周圍不動")   // l10n-ignore
        check(HPIconPress.look(t, animator: .center, k: 0, pressed: true) == HPIconPress.Look()
              && HPIconPress.look(t, animator: .center, k: 0, pressed: false) == HPIconPress.Look(), "圖示按壓：進度 0＝原樣")   // l10n-ignore
        check(HPIconPress.animator(t, reduceMotion: true) == .crossfade, "圖示按壓：減少動態效果走 crossfade")   // l10n-ignore
    }
}
