// 2.0 hello：產品版——一台機身照參考影片「躺著轉正 → 轉一整圈 → 螢幕亮起寫 hello」，逐格存 PNG（官網／宣傳素材）。
//
//   HOMEPLAY_RENDER_MODE=always .build/release/homeplay-pet --size 600 --at 30000,30000 --near --product-shot \
//       --finish silver [--view-mode wall] --hello-product <資料夾> [--hello-from 0 --hello-frames 223]
//
// 每次只拍一台（一種顏色／掛牆）；六台並排與錯開在 tooling/hello-composite.py 合成（錯開只是時間位移，不用重拍）。
// 怎麼重拍見 docs/plans/hello.md。
//
// 轉身的曲線量自參考影片（hellotools/fit2.py、yawknots.py）：
// - 轉正（躺 90° → 0°）：彈簧擬合得很好（rms 0.6°）——Spring(response 2.183, damping 0.672)，第 0.6 格起跑。
// - 轉一圈：彈簧擬合不好（臨界阻尼的節拍差 ±1.1 格且尾巴太慢；欠阻尼的會過衝 6°，影片裡看不到），
//   參考影片是關鍵影格做的，所以這裡照量到的角度走單調三次內插（Fritsch–Carlson），節拍誤差 ≤ 1 格。
import AppKit
import RealityKit
import simd

enum HelloProduct {
    private static func arg(_ name: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }
    static let outDir = arg("--hello-product")
    static let firstFrame = Int(arg("--hello-from") ?? "") ?? 0
    static let frameCount = Int(arg("--hello-frames") ?? "") ?? 223
    static var on: Bool { outDir != nil }

    static let pitchSpring = Spring(damping: 0.672, response: 2.183)
    static let pitchStartFrame = 0.6
    /// 轉一圈：(影格, 角度°)
    static let yawKnots: [(Double, Double)] = [
        (27, 0), (30, 9.8), (33, 19.8), (36, 31.8), (40, 49.4), (44, 67.1), (48, 84.4), (52, 100.7), (56, 122.3),
        (60, 145.5), (64, 171.8), (68, 199.5), (72, 219.1), (76, 244.7), (80, 262.1), (84, 272.9), (88, 286.0),
        (92, 298.5), (96, 309.5), (100, 319.0), (104, 327.2), (108, 334.1), (112, 340.0), (116, 345.5),
        (120, 350.5), (124, 355.5), (128, 359.2), (130, 360),   // 尾巴對上第 128 格停住（外框中心 ±1 px）
    ]

    /// 趴下的角度（°，90＝螢幕朝下趴平）
    static func pitch(frame n: Double) -> Double {
        let t = max(0, (n - pitchStartFrame) / HelloTimeline.fps)
        return Double(pitchSpring.value(from: 90, to: 0, velocity: 0, t: CGFloat(t)).x)
    }
    static func yaw(frame n: Double) -> Double { pchip(yawKnots, n) }

    /// 單調三次內插（Fritsch–Carlson），兩端斜率 0（從靜止起、停到靜止）
    static func pchip(_ k: [(Double, Double)], _ x: Double) -> Double {
        guard let f = k.first, let l = k.last else { return 0 }
        if x <= f.0 { return f.1 }
        if x >= l.0 { return l.1 }
        let n = k.count
        var d = [Double](repeating: 0, count: n - 1), m = [Double](repeating: 0, count: n)
        for i in 0..<(n - 1) { d[i] = (k[i + 1].1 - k[i].1) / (k[i + 1].0 - k[i].0) }
        for i in 1..<(n - 1) {
            if d[i - 1] * d[i] <= 0 { m[i] = 0; continue }
            let h0 = k[i].0 - k[i - 1].0, h1 = k[i + 1].0 - k[i].0
            let w1 = 2 * h1 + h0, w2 = h1 + 2 * h0
            m[i] = (w1 + w2) / (w1 / d[i - 1] + w2 / d[i])
        }
        var i = 0
        while i < n - 2 && x > k[i + 1].0 { i += 1 }
        let h = k[i + 1].0 - k[i].0, s = (x - k[i].0) / h
        let h00 = 2 * s * s * s - 3 * s * s + 1, h10 = s * s * s - 2 * s * s + s
        let h01 = -2 * s * s * s + 3 * s * s, h11 = s * s * s - s * s
        return h00 * k[i].1 + h10 * h * m[i] + h01 * k[i + 1].1 + h11 * h * m[i + 1]
    }

    /// 整機轉動的那一層（插在 holder 和它的錨點之間；holder 自己的縮放／浮動照舊）
    private static var spin: Entity?

    /// 轉軸：座台＝底座中心的鉛直線；掛牆＝螢幕模組中心
    static func pivot(wall: Bool) -> SIMD3<Float> { wall ? HomeViewModel.wallScreenCenter : SIMD3<Float>(0, 8, 0) }

    static func pose(frame n: Double, wall: Bool) -> (orientation: simd_quatf, position: SIMD3<Float>) {
        let p = Float(pitch(frame: n) * .pi / 180), y = Float(yaw(frame: n) * .pi / 180)
        // 一開始螢幕朝下趴著（頂邊往鏡頭倒；產品照鏡頭略低，看得到一線螢幕和上面的圓頂，跟參考第 0 格一樣），轉正時抬起來
        let q = simd_quatf(angle: y, axis: SIMD3<Float>(0, 1, 0)) * simd_quatf(angle: p, axis: SIMD3<Float>(1, 0, 0))
        let c = pivot(wall: wall)
        return (q, c - q.act(c))
    }

    /// AppDelegate 開完視窗後叫（main.swift 只有一行）
    static func startIfAsked(_ v: PetView) {
        guard let dir = outDir else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let holder = v.model.holder
        if let anchor = holder.parent {
            let s = Entity(); anchor.addChild(s); s.addChild(holder); spin = s
        }
        // 拆解用的生成內部件（主機板、天線…）：從下往上斜看時會透過蓋板玻璃上緣露出來，產品片不要
        func hideInternals(_ e: Entity) { if e.name.hasPrefix("anatomy.") { e.isEnabled = false } else { e.children.forEach(hideInternals) } }
        hideInternals(holder)
        let wall = v.model.wall
        HelloIntro.clockOverride = -1
        v.face.beginHello(CACurrentMediaTime())
        log("hello product: \(wall ? "wall" : "stand") frames \(firstFrame)..<\(frameCount) -> \(dir)")
        func shoot(_ n: Int) {
            if n >= frameCount { log("hello product: done"); exit(0) }
            let t = HelloTimeline.f(Double(n))
            HelloIntro.clockOverride = t
            v.face.helloStart = CACurrentMediaTime()   // 讓 hello 一直算「進行中」（時間看 clockOverride）
            let pose = pose(frame: Double(n), wall: wall)
            spin?.orientation = pose.orientation; spin?.position = pose.position
            v.face.forceDirty = true
            v.model.setScreen(v.face.render())
            v.requestFrame()
            // 等 RealityKit 出兩三幀，確定拍到的是這一格的姿勢與螢幕
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                v.captureSnapshot { img in
                    guard let img else { log("hello product: snapshot failed at \(n)"); exit(2) }
                    let url = URL(fileURLWithPath: dir).appendingPathComponent(String(format: "%03d.png", n))
                    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: url)
                    shoot(n + 1)
                }
            }
        }
        // 第一幀 RealityKit 可能要 20–60 s：先等場景與 USDZ 變體材質就緒
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { shoot(firstFrame) }
    }

    static func selftest(_ check: (Bool, String) -> Void) {
        check(abs(pitch(frame: 0) - 90) < 0.01 && abs(pitch(frame: 15) - 47) < 4 && abs(pitch(frame: 200)) < 1, "hello 產品：轉正彈簧（第 15 格約 45°）")
        // 量到的節拍：側面第 48.5 格、背面第 64.5 格、另一側第 83.5 格
        func at(_ deg: Double) -> Double {
            var lo = 27.0, hi = 130.0
            for _ in 0..<60 { let mid = (lo + hi) / 2; if yaw(frame: mid) < deg { lo = mid } else { hi = mid } }
            return lo
        }
        check(abs(at(90) - 48.5) <= 1 && abs(at(180) - 64.5) <= 1 && abs(at(270) - 83.5) <= 1, "hello 產品：轉身節拍誤差 ≤ 1 格")
        var mono = true
        for i in 0..<220 where yaw(frame: Double(i) + 0.5) < yaw(frame: Double(i)) - 1e-9 { mono = false }
        check(mono && yaw(frame: 10) == 0 && yaw(frame: 150) == 360, "hello 產品：轉身單調、靜止起停")
        let p = pose(frame: 222, wall: false)
        check(abs(p.orientation.angle.truncatingRemainder(dividingBy: 2 * .pi)) < 1e-3 || abs(p.orientation.angle - 2 * .pi) < 1e-3, "hello 產品：最後正對鏡頭")
    }
}
