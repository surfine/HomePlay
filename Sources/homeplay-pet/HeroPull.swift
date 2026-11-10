// README 片頭：同一台產品鏡頭，從螢幕上緣的眼睛拉到整機。
// 近景靠縮短距離，不靠事後放大（貼圖在近景加細，否則眼睛一放大就糊）。
//
//   HOMEPLAY_RENDER_MODE=always .build/release/homeplay-pet --size 900 --at 30000,30000 --near \
//       --product-shot --home --demo-official --finish silver --face idle --lang en \
//       --hero-pull /tmp/hp-hero/frames [--hero-from 0 --hero-frames 60]
import AppKit
import Foundation

enum HeroPull {
    private static func arg(_ name: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static let outDir = arg("--hero-pull")
    static let firstFrame = Int(arg("--hero-from") ?? "") ?? 0
    static let frameCount = Int(arg("--hero-frames") ?? "") ?? 60
    /// 對焦用：兩支都給了就整段鎖在這個機位，不走拉遠曲線。
    static let dollyArg = arg("--hero-dolly").flatMap { Float($0) }
    static let aimArg = arg("--hero-aim").flatMap { Float($0) }
    static var on: Bool { outDir != nil }

    /// 近景貼圖倍率。平常上限 2（2048²）；這裡只給這段片頭。
    static let textureScale: CGFloat = 4

    /// 每幀由 startIfAsked 寫入，PetView 的產品鏡頭讀它。
    static var dolly: Float = 1
    static var aimUp: Float = 0

    /// 近景對準缺口裡的眼睛，同時留著問候和一排圖示。0.45／0.45 是對過畫面的；0 是官圖整機。
    private static let eyeAim: Float = 0.45
    private static let closeDolly: Float = 0.45
    private static let holdIn = 10
    private static let travel = 36

    static func pose(frame n: Int) -> (dolly: Float, aimUp: Float) {
        if let d = dollyArg, let a = aimArg { return (d, a) }
        if n < holdIn { return (closeDolly, eyeAim) }
        let i = n - holdIn
        if i >= travel { return (1, 0) }
        let t = Float(i) / Float(travel - 1)
        let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        return (closeDolly + (1 - closeDolly) * e, eyeAim * (1 - e))
    }

    static func startIfAsked(_ v: PetView) {
        guard let dir = outDir else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let last = firstFrame + frameCount
        log("hero pull: frames \(firstFrame)..<\(last) -> \(dir)")
        func shoot(_ n: Int) {
            if n >= last { log("hero pull: done"); exit(0) }
            let p = pose(frame: n)
            dolly = p.dolly
            aimUp = p.aimUp
            log(String(format: "hero pull: frame %d dolly %.3f aim %.3f", n, p.dolly, p.aimUp))
            v.face.forceDirty = true
            v.model.setScreen(v.face.render())
            v.requestFrame()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                v.captureSnapshot { img in
                    guard let img else { log("hero pull: snapshot failed at \(n)"); exit(2) }
                    let url = URL(fileURLWithPath: dir).appendingPathComponent(String(format: "%03d.png", n))
                    let rep = NSBitmapImageRep(cgImage: v.compositeOverlays(img))
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                    shoot(n + 1)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { shoot(firstFrame) }
    }
}
