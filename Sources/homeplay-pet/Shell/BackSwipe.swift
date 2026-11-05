// 返回手勢的速度判定（HomeView 對齊後續 #2）：官方返回手勢用「距離＋釋放速度」複合決定
// 回不回（🟡 類別名實測、參數是推斷）。規則：拖過門檻就回；沒到門檻但拖過 45% 而且甩得快（輕掃）也回。
import AppKit

enum BackSwipe {
    /// 這次執行用的手感參數（後續 #8）：參數表的值，HOMEPLAY_BACKSWIPE 可以臨時覆寫
    static let tuning: BackSwipeTuning = ProcessInfo.processInfo.environment["HOMEPLAY_BACKSWIPE"]
        .map { BackSwipeTuning.parse($0, base: HPMotion.T.backSwipe) } ?? HPMotion.T.backSwipe

    /// 距離（pt，往返回方向的位移）＋釋放速度（pt/s，向返回方向為正）
    static func shouldBack(distance: CGFloat, velocity: CGFloat, threshold: CGFloat, tuning: BackSwipeTuning = BackSwipe.tuning) -> Bool {
        guard threshold > 0 else { return false }
        if distance >= threshold { return true }
        return distance >= threshold * tuning.minFraction && velocity > tuning.flickVelocity
    }

    /// 從拖動取樣算釋放速度（pt/s）：取最後 ~80 ms 的位移除以時間；樣本不足或時間倒流回 0
    static func releaseVelocity(_ samples: [(t: Double, x: CGFloat)], now: Double) -> CGFloat {
        guard let first = samples.first, let last = samples.last, last.t > first.t else { return 0 }
        let dt = last.t - first.t
        guard dt > 0.004 else { return 0 }
        return (last.x - first.x) / CGFloat(dt)
    }
}

// MARK: - 自檢

enum BackSwipeSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        let th: CGFloat = 18
        check(BackSwipe.shouldBack(distance: 20, velocity: 0, threshold: th), "返回：拖過門檻就回")   // l10n-ignore
        check(!BackSwipe.shouldBack(distance: 12, velocity: 0, threshold: th), "返回：沒到門檻、慢速不回")   // l10n-ignore
        check(BackSwipe.shouldBack(distance: 9, velocity: 1200, threshold: th), "返回：過 45% 門檻的快速輕掃也回")   // l10n-ignore
        check(!BackSwipe.shouldBack(distance: 9, velocity: 500, threshold: th), "返回：短而慢＝不回")   // l10n-ignore
        check(!BackSwipe.shouldBack(distance: 4, velocity: 3000, threshold: th), "返回：甩再快、位移太短不回（防誤觸）")   // l10n-ignore
        let t = 100.0
        let v = BackSwipe.releaseVelocity([(t: t, x: 100), (t: t + 0.05, x: 150), (t: t + 0.1, x: 200)], now: t + 0.1)
        check(abs(v - 1000) < 1e-6, "返回：速度取樣＝位移÷時間")   // l10n-ignore
        check(BackSwipe.releaseVelocity([(t: t, x: 100)], now: t) == 0, "返回：單一樣本沒有速度")   // l10n-ignore
        // 後續 #8：手感參數化
        let base = HPMotion.T.backSwipe
        check(base.minFraction == 0.45 && base.flickVelocity == 900, "返回：預設參數來自參數表（0.45／900）")   // l10n-ignore
        let o = BackSwipeTuning.parse("frac=0.5,vel=800", base: base)
        check(o.minFraction == 0.5 && o.flickVelocity == 800, "返回：HOMEPLAY_BACKSWIPE 覆寫解析正確")   // l10n-ignore
        check(BackSwipeTuning.parse("frac=1.5,vel=-3,foo=1,vel,frac=abc", base: base) == base && BackSwipeTuning.parse("vel=1200", base: base).minFraction == 0.45,
              "返回：不合法的值與不認得的鍵忽略、沿用表裡的值")   // l10n-ignore
        check(!BackSwipe.shouldBack(distance: 9, velocity: 1000, threshold: th, tuning: BackSwipeTuning(minFraction: 0.6, flickVelocity: 900))
              && BackSwipe.shouldBack(distance: 9, velocity: 850, threshold: th, tuning: o), "返回：判定照參數走（門檻與速度都可調）")   // l10n-ignore
    }
}
