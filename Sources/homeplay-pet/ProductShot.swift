// 2.0 device：--product-shot —— 照 Apple 官方正面產品圖的機位拍快照。
//
// 官圖（2576×2061）是沿螢幕法線看的長焦：螢幕 1:1 不變形（1282×1281），外框寬佔畫面 57.6%，
// 螢幕中心在畫面上 43.3% 的高度。官圖的螢幕是「扶正」的，底座幾乎是正側面（下緣弧度只有螢幕寬的
// 0.6%），而且底座比螢幕「遠」：寬只有正交投影的 0.94 倍。兩件事一起成立的機位是：鏡頭放低到底座
// 中段、略往上看（elevation −5°），螢幕跟著轉到正對鏡頭（不梯形），垂直視角 18°（約 64 cm 外）。
// 掃過 fov 3–22°、elevation −7…+3° 後，這組的底座寬／高／下緣弧度跟官圖差都在 0.5% 內。
// 這裡只給快照用，桌寵平常的鏡頭不動。
//   .build/release/homeplay-pet --size 900 --at 30000,30000 --near --product-shot --snapshot out.png
// 也可以給 --product-fov <度>（預設 18°）、--product-elev <度>（預設 −5，負＝鏡頭在下往上看）。
import CoreGraphics
import Foundation
import simd

enum ProductShot {
    static let on = CommandLine.arguments.contains("--product-shot")
    /// 官圖畫布比例（寬 / 高）
    static let aspect: CGFloat = 2576.0 / 2061.0
    /// 垂直視角（度）
    static let fov: Float = {
        if let i = CommandLine.arguments.firstIndex(of: "--product-fov"), i + 1 < CommandLine.arguments.count,
           let v = Float(CommandLine.arguments[i + 1]), v > 0.1, v < 60 { return v }
        return 18
    }()
    /// 螢幕法線的仰角（度）：鏡頭沿這條法線看；負＝鏡頭在螢幕中心下方往上看（官圖反推 −5°）
    static let elevation: Float = {
        if let i = CommandLine.arguments.firstIndex(of: "--product-elev"), i + 1 < CommandLine.arguments.count,
           let v = Float(CommandLine.arguments[i + 1]), v > -30, v < 30 { return v }
        return -5
    }() * .pi / 180
    /// 鉸鏈要轉的角度（把 USDZ 自帶的後仰轉回只剩 elevation）
    static func rigPitch(tilt: Float) -> Float { tilt - elevation }
    /// 鉸鏈轉過 rigPitch 後顯示面中心（世界座標 cm）；dy、dz 是顯示面中心相對鉸鏈的位移
    static func screenCenter(hinge: SIMD3<Float>, dy: Float, dz: Float, tilt: Float) -> SIMD3<Float> {
        let a = rigPitch(tilt: tilt)
        return hinge + SIMD3<Float>(0, dy * cosf(a) - dz * sinf(a), dy * sinf(a) + dz * cosf(a))
    }
    /// 棚拍 IBL 的曝光（2 的次方；--product-ibl 可改）：官圖是高調白棚，比桌寵平常亮一級。
    /// 掃過 0／0.5／1／1.5：1 時銀色外框側面中位 208（官圖 204）、網罩亮處 219（214）
    static let iblExponent: Float = {
        if let i = CommandLine.arguments.firstIndex(of: "--product-ibl"), i + 1 < CommandLine.arguments.count,
           let v = Float(CommandLine.arguments[i + 1]), v > -4, v < 4 { return v }
        return 1
    }()
    /// 外框寬 ÷ 畫面寬、螢幕中心距頂 ÷ 畫面高（官圖量的）
    static let frameOfWidth: Float = 1484.0 / 2576.0
    static let screenCenterFromTop: Float = 892.0 / 2061.0
    /// 外框寬 ÷ 螢幕寬（官圖 1.158）；螢幕寬用模型的 screenSize（cm）
    static let frameOverScreen: Float = 1.158

    /// 鏡頭姿勢：沿顯示面法線（後仰 tilt）對準顯示面中心，回傳位置、俯仰（弧度）
    static func camera(screenCenter c: SIMD3<Float>, tilt: Float, screenWidth: Float) -> (position: SIMD3<Float>, pitch: Float) {
        let viewW = screenWidth * frameOverScreen / frameOfWidth
        let viewH = viewW / Float(aspect)
        let d = (viewH / 2) / tanf(fov / 2 * .pi / 180)
        let n = SIMD3<Float>(0, sinf(tilt), cosf(tilt))          // 螢幕法線
        let up = SIMD3<Float>(0, cosf(tilt), -sinf(tilt))       // 畫面的上方
        // 螢幕中心在畫面中線上方 (0.5 − 0.433)·viewH：鏡頭中心往下挪這麼多
        let target = c - up * ((0.5 - screenCenterFromTop) * viewH)
        return (target + n * d, tilt)
    }

    /// 自檢：鏡頭在法線上、距離合理、螢幕中心落在畫面 43% 高
    static func selftest(_ check: (Bool, String) -> Void) {
        let c = SIMD3<Float>(0, 10.46, 4.28), t: Float = 0.35
        let (p, pitch) = camera(screenCenter: c, tilt: t, screenWidth: 12.54)
        check(abs(pitch - t) < 1e-6, "product shot：俯仰＝螢幕後仰")
        let viewH = 12.54 * frameOverScreen / frameOfWidth / Float(aspect)
        let fwd = -SIMD3<Float>(0, sinf(t), cosf(t)), up = SIMD3<Float>(0, cosf(t), -sinf(t))
        let rel = c - p
        let depth = simd_dot(rel, fwd)
        let y = simd_dot(rel, up) / (depth * tanf(fov / 2 * .pi / 180))   // −1…1，+ 往上
        let centred = abs((0.5 - y / 2) - screenCenterFromTop) < 0.002 && abs(viewH - 20.18) < 0.1
        check(centred, "product shot：螢幕中心在畫面 43.3% 高")
    }
}
