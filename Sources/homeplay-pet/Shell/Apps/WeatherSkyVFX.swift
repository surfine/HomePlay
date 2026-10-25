// 天氣 App 的動態天空——系統那條：直接用系統天氣 App 自己的 VFX 場景來畫。
// 來源：macOS 27 的 /System/Library/PrivateFrameworks/VFX.framework（原生 macOS 版的 Apple VFX 引擎）
//      ＋ WeatherUI.framework 資源裡的 WeatherV136_Default_Background.vfx（天氣 App 背景的整個場景：
//      漸層天空、四層雲、雨／雪／冰雹／霰、星星、太陽光暈與彩虹、月亮與月相、閃電、風、霧的噪聲片；278 個可調綁定）。
// 執行時從系統讀，不複製進 repo 或 App；類別、方法或場景檔不在就回 nil。
// 已知限制（2026-10-25 實測）：場景是「匯出版」，粒子初始化／更新與 105 張邏輯圖是預先編進 WeatherUI 執行檔的 146 支腳本，
// 只有天氣 App（Catalyst 行程）載得到；我們的行程載不到 WeatherUI，所以場景能畫、能調參數，但粒子沒初始化，約三分之一幀整片純白。
// 所以 WeatherLiveSky 的健檢會擋下它、改用 WeatherSkyMetal；這條留著，系統哪天把腳本搬進 VFX 或場景就會自動用上。
// 呼叫端（WeatherLiveSky）保證所有呼叫都在同一條序列佇列。

import AppKit
import CoreImage
import Metal
import QuartzCore

/// 寫進 VFX 綁定的參數；鍵是「物件.綁定名」，沒有點＝MAIN
struct WeatherSkyParams: Equatable {
    var floats: [String: Float] = [:]
    var vectors: [String: [Float]] = [:]
    var ints: [String: Int] = [:]
    var bools: [String: Bool] = [:]
}

final class WeatherSkyVFX {
    static let sceneURL = URL(fileURLWithPath:
        "/System/iOSSupport/System/Library/PrivateFrameworks/WeatherUI.framework/Versions/A/Resources/VFX/WeatherV136_Default_Background.vfx")
    static let frameworkPath = "/System/Library/PrivateFrameworks/VFX.framework/VFX"

    let side: Int
    private let device: MTLDevice
    private let renderer: NSObject
    private let effect: NSObject
    private let ci: CIContext
    private let snapSel = NSSelectorFromString("snapshotWithSize:deltaTime:")
    private let ptrSel = NSSelectorFromString("withPointerToParameterOf:named:block:")
    private typealias SnapFn = @convention(c) (AnyObject, Selector, CGSize, Double) -> AnyObject?
    private typealias PtrFn = @convention(c) (AnyObject, Selector, NSString, NSString, @convention(block) (UnsafeMutableRawPointer) -> Void) -> Void
    private let snapImp: SnapFn
    private let ptrImp: PtrFn

    private var applied: WeatherSkyParams?

    /// selftest：假裝系統的類別不在，走「找不到 → 退路」那條
    nonisolated(unsafe) static var simulateMissing = false
    static func make(side: Int = 1024) -> WeatherSkyVFX? {
        if simulateMissing || ProcessInfo.processInfo.environment["HOMEPLAY_NO_VFX"] != nil { return nil }
        return WeatherSkyVFX(side: side)
    }

    private init?(side: Int = 1024) {
        self.side = side
        guard FileManager.default.fileExists(atPath: Self.sceneURL.path),
              dlopen(Self.frameworkPath, RTLD_NOW) != nil,
              let device = MTLCreateSystemDefaultDevice(),
              let sceneClass = NSClassFromString("_TtC3VFX8VFXScene") as? NSObject.Type,
              let rendererClass = NSClassFromString("VFXRenderer") as? NSObject.Type else { return nil }
        self.device = device
        let scene = sceneClass.init()
        let addSel = NSSelectorFromString("addEffectFrom:error:")
        guard scene.responds(to: addSel) else { return nil }
        typealias AddFn = @convention(c) (AnyObject, Selector, NSURL, UnsafeMutablePointer<NSError?>?) -> AnyObject?
        var err: NSError?
        guard let addImp = scene.method(for: addSel),
              let fx = unsafeBitCast(addImp, to: AddFn.self)(scene, addSel, Self.sceneURL as NSURL, &err) as? NSObject else { return nil }
        let mkSel = NSSelectorFromString("rendererWithDevice:options:")
        typealias MkFn = @convention(c) (AnyObject, Selector, AnyObject, AnyObject?) -> AnyObject?
        guard rendererClass.responds(to: mkSel), let mkImp = (rendererClass as AnyObject).method(for: mkSel),
              let r = unsafeBitCast(mkImp, to: MkFn.self)(rendererClass, mkSel, device, nil) as? NSObject,
              r.responds(to: snapSel), fx.responds(to: ptrSel),
              let si = r.method(for: snapSel), let pi = fx.method(for: ptrSel) else { return nil }
        r.setValue(scene, forKey: "scene")
        renderer = r; effect = fx
        snapImp = unsafeBitCast(si, to: SnapFn.self)
        ptrImp = unsafeBitCast(pi, to: PtrFn.self)
        ci = CIContext(mtlDevice: device, options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                                      .cacheIntermediates: false])
    }

    /// 換參數：只寫有變的綁定。VFX 的粒子系統自己會漸變（新粒子照新參數生）。
    func configure(_ p: WeatherSkyParams) {
        guard p != applied else { return }
        apply(p, from: applied); applied = p
    }

    /// 前進 dt 秒畫一張（同步等 GPU，約 4 ms／1024²）；回 sRGB 的 CGImage
    func renderFrame(dt: Double) -> CGImage? {
        let t0 = CACurrentMediaTime()
        guard let tex = snapImp(renderer, snapSel, CGSize(width: side, height: side), dt) as? MTLTexture,
              let ciImg = CIImage(mtlTexture: tex, options: [.colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!]) else { return nil }
        // Metal 貼圖原點在左上、CI 在左下：翻回來
        let flipped = ciImg.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -ciImg.extent.height))
        let img = ci.createCGImage(flipped, from: flipped.extent, format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        _ = t0
        return img
    }


    // MARK: 場景 → VFX 綁定（綁定名與預設值是從場景讀出來的，見 docs/plans/weather-sky.md 附錄）
    static func params(for scene: WeatherSkyScene) -> WeatherSkyParams {
        let l = scene.look
        var p = WeatherSkyParams()
        func col(_ c: SkyRGB) -> [Float] { let v = c.linear; return [v.x, v.y, v.z, 1] }
        p.vectors["gradientTop"] = col(l.top); p.vectors["gradientMiddle"] = col(l.middle); p.vectors["gradientBottom"] = col(l.bottom)
        // 降水（場景預設全開，數量照我們的外觀；0 會讓場景整片白，所以最少留 1）
        p.floats["rainBGParticleCount"] = Float(max(1, l.rainBG * 2)); p.floats["rainFGParticleCount"] = Float(max(1, l.rainFG * 4))
        p.floats["snowBGParticleCount"] = Float(max(1, l.snowBG * 2)); p.floats["snowFGParticleCount"] = Float(max(1, l.snowFG * 4))
        p.floats["hailParticleCount"] = Float(max(1, l.hail * 3)); p.floats["sleetBGParticleCount"] = Float(max(1, l.sleet * 3)); p.floats["sleetFGParticleCount"] = Float(max(1, l.sleet))
        p.floats["windParticleAmount"] = l.wind * 8
        p.floats["noiseParticleCount"] = l.fog * 3
        p.floats["foregroundParticlesParticleCount"] = 0
        // 星、月、太陽
        p.floats["starOpacity"] = l.stars; p.ints["starParticleCount"] = l.stars > 0 ? 1000 : 1; p.ints["starBrightParticleCount"] = l.stars > 0 ? 133 : 1
        p.floats["Moon.moonElevation"] = l.moon > 0 ? 25 : -60
        p.floats["Moon.moonPhaseAngle"] = Float(scene.moonPhase) / 28 * 360
        p.floats["sunFlareOverAllScale"] = l.sunDisc * 1.5
        p.floats["sunRainbowOpacity"] = 0; p.floats["sunRainbowSunPathOpacity"] = 0
        p.floats["sunRaysParticleCount"] = l.sunDisc > 0 ? 3 : 0
        // 雲：每層的數量
        let n = l.clouds.reduce(0) { $0 + $1.count }
        p.ints["cloudBGParticleCount"] = max(1, n); p.ints["cloudFGParticleCount"] = max(1, n)
        p.ints["cloudBBGParticleCount"] = max(1, n / 2); p.ints["cloudFFGParticleCount"] = max(1, n / 3)
        // 閃電
        p.floats["lightningCloudFlashProbability"] = l.lightning ? 0.5 : 0
        p.floats["Lightning.lightningScreenFlashProbability"] = l.lightning ? 0.75 : 0
        return p
    }

    // MARK: 寫參數（直接寫進 VFX 綁定的記憶體；型別照場景裡的綁定：Float／SIMD2／SIMD3／SIMD4／Int32／Bool）

    private func write(_ object: String, _ name: String, _ body: @escaping (UnsafeMutableRawPointer) -> Void) {
        ptrImp(effect, ptrSel, object as NSString, name as NSString, body)
    }
    func setFloat(_ name: String, _ v: Float, object: String = "MAIN") { write(object, name) { $0.storeBytes(of: v, as: Float.self) } }
    func setVec(_ name: String, _ v: [Float], object: String = "MAIN") {
        write(object, name) { p in for (i, x) in v.enumerated() { p.storeBytes(of: x, toByteOffset: i * 4, as: Float.self) } }
    }
    func setInt(_ name: String, _ v: Int, object: String = "MAIN") { write(object, name) { $0.storeBytes(of: Int32(v), as: Int32.self) } }
    func setBool(_ name: String, _ v: Bool, object: String = "MAIN") { write(object, name) { $0.storeBytes(of: UInt8(v ? 1 : 0), as: UInt8.self) } }

    private func apply(_ p: WeatherSkyParams, from old: WeatherSkyParams?) {
        for (k, v) in p.floats where old?.floats[k] != v { let (o, n) = Self.split(k); setFloat(n, v, object: o) }
        for (k, v) in p.vectors where old?.vectors[k] != v { let (o, n) = Self.split(k); setVec(n, v, object: o) }
        for (k, v) in p.ints where old?.ints[k] != v { let (o, n) = Self.split(k); setInt(n, v, object: o) }
        for (k, v) in p.bools where old?.bools[k] != v { let (o, n) = Self.split(k); setBool(n, v, object: o) }
    }
    /// "Moon.moonElevation" → ("Moon", "moonElevation")；沒有點＝MAIN
    static func split(_ key: String) -> (String, String) {
        guard let dot = key.firstIndex(of: ".") else { return ("MAIN", key) }
        return (String(key[..<dot]), String(key[key.index(after: dot)...]))
    }
}
