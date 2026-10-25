// 天氣 App 動態天空的總管：選畫家、排幀、暫停。
// 預設先試系統的天氣渲染器（WeatherSkyVFX：系統 VFX 引擎＋天氣 App 自己的場景），試畫一段做健檢；
// 健檢不過（類別或符號不在、畫不出來、畫出整片同色——今天在 macOS 27 上就是這樣：WeatherUI 預先編好的 146 支場景腳本
// 只在天氣 App 自己的行程裡，我們載入時那些粒子沒有初始化，約三分之一的幀整片純白）就安靜地改用我們自己的 Metal 天空（WeatherSkyMetal）。
// 跑起來以後也一直看：系統那條連續出現整片同色的幀，就換成我們的，不再回頭。
// 強制：HOMEPLAY_WEATHER_SKY=system｜ours；selftest 用 forceFallback 走退路那條。
// 執行緒：畫家都在 queue 上跑；主執行緒只拿上一張成品，不等 GPU。沒人要幀（App 沒在畫）就不排，等於暫停。

import AppKit
import QuartzCore

final class WeatherLiveSky {
    enum Source: String { case system, ours, none }

    nonisolated(unsafe) static var shared = WeatherLiveSky()
    /// 外殼：天氣 App 正在播動態天空時維持 60 fps（停止要幀 0.5 s 就放掉）
    nonisolated(unsafe) static var lastDemand: Double = -1
    static func wantsFrames(_ now: Double) -> Bool { lastDemand >= 0 && now - lastDemand < 0.5 }

    private let queue = DispatchQueue(label: "homeplay.weather.sky", qos: .userInteractive)
    private let lock = NSLock()
    private var latest: CGImage?
    private var serialNo = 0
    private var busy = false
    private var lastAt: Double = -1
    private var scene: WeatherSkyScene?
    private var sceneApplied: WeatherSkyScene?
    private var ours: WeatherSkyMetal?
    private var system: WeatherSkyVFX?
    private var probed = false
    private var uniformStreak = 0
    private(set) var source: Source = .none
    /// 為什麼沒用系統的（報告、selftest 看）
    private(set) var fallbackReason = ""
    /// 每幀耗時（ms，畫家內 GPU＋讀回），給量測用
    private(set) var frameMs: [Double] = []

    let forceFallback: Bool
    init(forceFallback: Bool = false) { self.forceFallback = forceFallback }

    var serial: Int { lock.lock(); defer { lock.unlock() }; return serialNo }

    /// 模組的框（1024 畫布座標）：雨在上緣濺水花
    func setColliders(_ rects: [CGRect]) {
        let n = rects.map { CGRect(x: $0.minX / 1024, y: $0.minY / 1024, width: $0.width / 1024, height: $0.height / 1024) }
        queue.async { self.ours?.colliders = n }
    }

    /// 換場景；畫家在下一幀交叉淡入
    private var lastConfigured: WeatherSkyScene?
    func configure(_ s: WeatherSkyScene) {
        guard s != lastConfigured else { return }     // 每幀都會叫：一樣就不排
        lastConfigured = s
        queue.async { self.scene = s }
    }

    /// 輸出邊長（像素）：跟螢幕畫布一樣大，主執行緒就能 1:1 貼上（不用每幀縮放 1024² → 畫布，那一步要 8 ms）
    private var side = 1024

    /// 主執行緒每次畫天氣 App 時叫：回上一張成品並排下一幀。animate＝false（減少動態效果）只在換場景時重畫一張靜態的。
    func frame(now: Double, animate: Bool, side px: Int = 1024) -> CGImage? {
        WeatherLiveSky.lastDemand = animate ? now : -1
        let px = max(256, min(2048, px))
        queue.async { if self.side != px { self.side = px; self.ours = nil; if self.source == .ours { self.source = .none; self.probed = false } } }
        lock.lock(); let img = latest; lock.unlock()
        queue.async { [weak self] in self?.renderNext(now: now, animate: animate, have: img != nil) }
        return img
    }

    /// 快照／量測：同步走 n 幀（固定步進），回最後一張
    @discardableResult
    func renderSync(frames n: Int, dt: Double = 1.0 / 60, each: ((Int, CGImage) -> Void)? = nil) -> CGImage? {
        var out: CGImage?
        queue.sync {
            for i in 0..<max(1, n) { if let img = step(dt: dt, motion: true) { out = img; each?(i, img) } }
        }
        if let out { lock.lock(); latest = out; serialNo += 1; lock.unlock() }
        return out
    }

    private func renderNext(now: Double, animate: Bool, have: Bool) {
        guard !busy else { return }
        // 減少動態效果：天空停住；換場景時照樣淡入（淡入期間繼續排幀，淡完就停）
        if !animate, have, scene == sceneApplied, !(ours?.isBlending ?? false) { lastAt = now; return }
        busy = true; defer { busy = false }
        let dt = lastAt < 0 ? 1.0 / 60 : min(0.1, max(1.0 / 240, now - lastAt))
        lastAt = now
        guard let img = step(dt: dt, motion: animate) else { return }
        lock.lock(); latest = img; serialNo += 1; lock.unlock()
    }

    // MARK: 選畫家（queue 上）

    private func step(dt: Double, motion: Bool) -> CGImage? {
        guard let s = scene else { return nil }
        if !probed { probed = true; choose(s) }
        let t0 = CACurrentMediaTime()
        var img: CGImage?
        switch source {
        case .system:
            if s != sceneApplied, let v = system { v.configure(WeatherSkyVFX.params(for: s)) }
            img = system?.renderFrame(dt: motion ? dt : 0)
            // 執行中的健檢：連續 3 張整片同色（或畫不出來）就換成我們的
            if img == nil || img.map(Self.isUniform) == true { uniformStreak += 1 } else { uniformStreak = 0 }
            if uniformStreak >= 3 {
                fallbackReason = "system renderer produced uniform frames at runtime"
                useOurs(s); img = ours?.render(dt: dt, motion: motion)
            }
        case .ours:
            if s != sceneApplied { ours?.configure(s, crossfade: sceneApplied != nil) }
            img = ours?.render(dt: dt, motion: motion)
        case .none:
            return nil
        }
        sceneApplied = s
        if frameMs.count < 4000 { frameMs.append((CACurrentMediaTime() - t0) * 1000) }
        return img
    }

    /// 系統渲染器健檢的結果，每個系統版本只試一次（不過的話之後打開就直接用我們的，不再花 2 秒試）
    private static var probeKey: String { "weatherSky.systemProbe." + ProcessInfo.processInfo.operatingSystemVersionString }

    private func choose(_ s: WeatherSkyScene) {
        let env = ProcessInfo.processInfo.environment["HOMEPLAY_WEATHER_SKY"]
        if forceFallback { fallbackReason = "forced (selftest)"; useOurs(s); return }
        if env == "ours" { fallbackReason = "HOMEPLAY_WEATHER_SKY=ours"; useOurs(s); return }
        guard let v = WeatherSkyVFX.make(side: side) else {
            fallbackReason = "system VFX renderer unavailable (class, symbol or scene missing)"; useOurs(s); return
        }
        if env != "system", let r = UserDefaults.standard.string(forKey: Self.probeKey), r.hasPrefix("fail") {
            fallbackReason = "system VFX probe failed earlier on this OS (\(r))"; useOurs(s); return
        }
        // 健檢：先用我們的（不讓第一次打開等 2 秒），系統那條在另一條佇列用要畫的場景試畫 3 秒
        //（180 幀、離線步進）；整片同色超過 2 張就不用，結果記下來（每個系統版本一次）
        useOurs(s)
        fallbackReason = "system VFX probe running"
        let force = env == "system"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            v.configure(WeatherSkyVFX.params(for: s))
            var bad = 0
            let total = 180
            for _ in 0..<total {
                guard let img = v.renderFrame(dt: 1.0 / 60) else { bad += 1; continue }
                if Self.isUniform(img) { bad += 1 }
            }
            let pass = bad <= 2 || force
            UserDefaults.standard.set(pass ? "pass" : "fail \(bad)/\(total)", forKey: Self.probeKey)
            self?.queue.async {
                guard let self else { return }
                if pass { self.system = v; self.source = .system; self.sceneApplied = nil; self.fallbackReason = "" }
                else { self.fallbackReason = "system VFX probe failed: \(bad)/\(total) frames blank or uniform" }
            }
        }
    }

    private func useOurs(_ s: WeatherSkyScene) {
        system = nil; source = .none
        if ours == nil { ours = WeatherSkyMetal(side: side, scene: s) }
        source = ours == nil ? .none : .ours
        if ours == nil { fallbackReason += "; Metal recreation unavailable" }
    }

    /// 整片同色（純白、純黑、清空色）：取 4×4 縮圖，16 個點的差距 < 2/255
    static func isUniform(_ img: CGImage) -> Bool {
        let n = 4
        guard let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let p = { c.interpolationQuality = .low; c.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n)); return c.data?.assumingMemoryBound(to: UInt8.self) }()
        else { return true }
        var lo = [255, 255, 255], hi = [0, 0, 0]
        for i in 0..<(n * n) { for ch in 0..<3 { let v = Int(p[i * 4 + ch]); lo[ch] = min(lo[ch], v); hi[ch] = max(hi[ch], v) } }
        return (0..<3).allSatisfy { hi[$0] - lo[$0] < 2 }
    }
}
