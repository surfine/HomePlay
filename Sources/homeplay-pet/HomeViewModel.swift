import AppKit
import ApplicationServices
import AVFoundation
import Metal
import RealityKit
import Combine
import simd
import VideoToolbox
import CoreMedia
import CoreImage
import ImageIO
import IOKit.ps
import IOKit.hid
import Carbon.HIToolbox
import Network
import EventKit
import ServiceManagement
import Security

// MARK: - 模型（照「HomeView 拆解」稿：单位、位置、偏移都从稿里搬）

/// 外观：G4 白（白色亮面塑料，屏幕走 Aqua）或真机四色铝。铝色是照产品图估的近似值，不是官方色码。
enum Finish: String, CaseIterable {
    case g4, silver, starlight, rose, gray
    var title: String {
        switch self {
        case .g4: return L("finish.g4", "G4 白")
        case .silver: return L("finish.silver", "银色")
        case .starlight: return L("finish.starlight", "星光色")
        case .rose: return L("finish.rose", "玫瑰粉")
        case .gray: return L("finish.gray", "深空灰")
        }
    }
    var aluminum: UInt32? {
        switch self {
        case .g4: return nil
        case .silver: return 0xc0c2c6
        case .starlight: return 0xd0c3ae
        case .rose: return 0xd6bab3
        case .gray: return 0x5d5f64
        }
    }
    static let defaultsKey = "HomePlayFinish"
}

/// RealityKit 版机身：直接载入 Apple 的 USDZ，几何和材质原生。
/// 换铝色时网罩仍用原生孔洞遮罩，只替换成同色 PBR，孔洞和孔后的深色衬里都保留。
/// 相机、铰链、表情贴图、拆解、配色都保持原来的语义。
final class HomeViewModel {
    // 实测（cm）：屏幕面中心 y=10.46，铰链 y=7.20，屏幕后仰 20°
    static let tilt: CGFloat = 0.35
    static let rigY: CGFloat = 10.46
    static let hingeY: CGFloat = 7.20
    static let rigHome = SIMD3<Float>(0, 7.20, 3.80)
    /// 拆開時螢幕組整個離開底座的位移
    static let screenLift = SIMD3<Float>(0, 9.5, 3.0)

    /// 世界单位是厘米：USDZ 根节点自带 0.01（米），再乘 100 回到厘米。
    let holder = Entity()
    /// 屏幕组绕真实铰链转（追人/点头/摇头）
    let screenPivot = Entity()
    /// 隐藏的屏幕平面：只有变换，用来算触控 UV / 投影
    let screenAnchor = Entity()

    private(set) var finish: Finish = .starlight
    private var usdzRoot: Entity?
    private var baseGroup: Entity?
    private var screenGroup: Entity?
    private var screenBack: Entity?
    private var displayNode: ModelEntity?
    private var displayLoaded = false

    /// 屏幕贴图：脸的 CGImage 或直播的 MTLTexture。
    private var screenTexture: TextureResource?
    private var screenMaterial = HomeViewModel.makeScreenMaterial()
    /// 場景「看得見的變化」計數：貼圖、材質換了就加一。PetView 以此決定要不要讓 RealityKit 出幀。
    private(set) var generation = 0

    private struct BodyPart {
        let entity: ModelEntity
        let materials: [any Material]
    }
    private var bodyParts: [BodyPart] = []

    /// 三层网罩：外层冲孔板、内层孔衬、最里面的实心衬底。
    /// 孔洞来自 USDZ 自带的 opacity 遮罩，换材质时仍然保留。
    private var grilleParts: [BodyPart] = []
    private var screenGrillePart: BodyPart?
    private var grilleInnerParts: [BodyPart] = []
    private var grilleBackingParts: [BodyPart] = []
    private var grilleMask: TextureResource?
    private var usbPort: USBCPortAssembly?

    /// 拆解時逐件位移：九層（見 Anatomy.swift）各自一個時間窗，外層先動。只平移，不轉。
    private struct ExplodeMover {
        let entity: Entity
        let origin: SIMD3<Float>
        let offset: SIMD3<Float>
        let layer: AnatomyLayer
    }
    private var explodeMovers: [ExplodeMover] = []
    /// 生成的內部件與 USB‑C 母座：實體 → 哪一件（USDZ 零件用節點名查 AnatomyPart.usdz）
    private var anatomyParts: [ObjectIdentifier: AnatomyPart] = [:]
    /// 螢幕座標容器：原點＝顯示面中心，+z＝螢幕法線（後仰 20°）。生成的螢幕內部件放這裡。
    private let anatomyScreen = Entity()
    private var anatomyFrame: Entity?
    private var anatomyRadiators: [(Entity, Float)] = []
    private var anatomyWoofer: Entity?
    private var anatomyPower: Entity?
    private(set) var anatomyGenerated: [ModelEntity] = []
    private var picker: AnatomyPicker?

    /// 给 ARView.hitTest 用的不可见碰触盒（包住整机）
    private(set) var hitBody = Entity()

    private static func makeScreenMaterial() -> UnlitMaterial {
        if #available(macOS 15.0, *) {
            // 脸是自发光 UI，不要再过一遍场景的色调映射
            return UnlitMaterial(applyPostProcessToneMap: false)
        }
        return UnlitMaterial()
    }

    init() {
        holder.name = "homeview"
        holder.scale = SIMD3<Float>(repeating: 100)
        screenPivot.name = "screenPivot"
        screenPivot.position = Self.rigHome
        screenAnchor.name = "screenAnchor"
        screenAnchor.position = SIMD3<Float>(0, Float(Self.rigY - Self.hingeY), 4.28 - Self.rigHome.z)
        screenAnchor.orientation = simd_quatf(angle: -Float(Self.tilt), axis: SIMD3<Float>(1, 0, 0))

        guard let url = Bundle.module.url(forResource: "apple-homeview", withExtension: "usdz") else {
            log("USDZ 不在资源包里：apple-homeview.usdz")
            return
        }
        do {
            let root = try Entity.load(contentsOf: url)
            usdzRoot = root
            root.name = "usdz"
            // 只要机器本体：USB-C 线整组隐藏，旧的米色端口占位由新的母座取代。
            root.findEntity(named: "tLEDFVYGwydBKWm")?.isEnabled = false
            root.findEntity(named: "FotmOZuSlJsjcoC")?.isEnabled = false
            holder.addChild(root)
            guard let base = root.findEntity(named: "NJhDUJBxvaEheAQ"),
                  let screen = root.findEntity(named: "CnqMXaudxjxUchB"),
                  let display = root.findEntity(named: "RFkcSjAtJLGqwDA") as? ModelEntity,
                  let parent = base.parent else {
                log("USDZ 结构不符：找不到底座 / 屏幕组 / 显示面")
                return
            }
            baseGroup = base
            screenGroup = screen
            displayNode = display
            screenBack = root.findEntity(named: "YGumwFJYyjNDAsM")

            // 屏幕和它的背板一起绕铰链转；背板在 RealityKit 的层级里是屏幕组的兄弟。
            parent.addChild(screenPivot)
            let hingeOffset = SIMD3<Float>(-Self.rigHome.x, -Self.rigHome.y, -Self.rigHome.z)
            screen.removeFromParent()
            screen.position = hingeOffset
            screenPivot.addChild(screen)
            if let back = screenBack {
                back.removeFromParent()
                back.position = hingeOffset
                screenPivot.addChild(back)
            }
            screenPivot.addChild(screenAnchor)

            // 拆解：底座向下，屏幕组沿铰链向上/向前，和旧版一致。
            // （apply(apart:) 里做）

            // 需要随配色变的外壳件：圆顶、屏幕背板、脚圈。
            for name in ["SZbxWWDrhdKpHNV", "YGumwFJYyjNDAsM", "nLuFOBqijsErMHq"] {
                guard let e = root.findEntity(named: name) as? ModelEntity,
                      let mats = e.model?.materials else { continue }
                bodyParts.append(BodyPart(entity: e, materials: mats))
            }

            // 两层冲孔网罩：外层跟机身色，内层是孔后的衬里。
            if let url = Bundle.module.url(forResource: "grille-opacity", withExtension: "png"),
               let mask = try? TextureResource.load(
                   contentsOf: url, withName: "grille-opacity",
                   options: .init(semantic: .raw, mipmapsMode: .allocateAndGenerateAll)) {
                grilleMask = mask
            } else {
                log("网罩遮罩缺失：grille-opacity.png")
            }
            for name in ["UQXoGTWKtdzyKWe", "XVYJNqpXsKfyxeD"] {
                guard let e = root.findEntity(named: name) as? ModelEntity,
                      let mats = e.model?.materials else { continue }
                let part = BodyPart(entity: e, materials: mats)
                grilleParts.append(part)
                if name == "XVYJNqpXsKfyxeD" { screenGrillePart = part }
            }
            for name in ["MuiTShOwADSblaI", "abNOzwnQJCCmxBx", "XYBCaNnSjiUiVLG",
                         "hrvrGcFkksrqTSI", "UrfQEzgVYVBUcSJ", "bcOVqgjhplwbkKv",
                         "OcZtYhDfBEBtfeO", "flbFkoPfVvSJBeb", "dKHDPuhaFtUISBz",
                         "tCgJhsEVvDMYgwY", "uKjHAcdgWcDXweZ", "HbOtaaAKzfYczkG",
                         "ChgAKgifeVFuTFO", "VqHunENsfOpXgiN", "lzRnsDzlWFniRdS",
                         "ZLAybMqalONgsGI", "FaPQPfblXqKHgfB", "wLRregyQoxWPJXL",
                         "vpysVCdjxGIfzju", "XTKeTnQSfyVvXZA", "fSuRFdZlyZrdMsV",
                         "rGBGcYiyQwpYdtT", "pcAsQphSQfzGjTz", "NWYWxqlRejAmgQs",
                         "PfAHaXCVHUTzQAm", "JPTNGKSjPowVptr", "uudmqgTXWDqUCES",
                         "bxiioNiAJxmpQhR"] {
                guard let e = root.findEntity(named: name) as? ModelEntity,
                      let mats = e.model?.materials else { continue }
                grilleInnerParts.append(BodyPart(entity: e, materials: mats))
            }
            for name in ["GkdQECEsVboLhOs", "iKNLnLHtbywYoYi"] {
                guard let e = root.findEntity(named: name) as? ModelEntity,
                      let mats = e.model?.materials else { continue }
                grilleBackingParts.append(BodyPart(entity: e, materials: mats))
            }

            // 背面 USB-C：母座沉在原生凹槽底部。
            let port = USBCPortAssembly()
            port.root.position = SIMD3<Float>(0, 1.537, -4.100)
            base.addChild(port.root)
            usbPort = port
            buildAnatomy(base: base, screen: screen)




            // 触控/拖动的机身命中：每个网格零件各自一个碰撞盒（跟着拆解位移走），
            // 取代以前的整机 AABB——那个盒子把底座两侧、屏幕上方的透明区都算成「机身」，
            // 双指滑动在空白处也会转身体（2026-10-22 手势冲突）。
            var collisionParts = 0
            func addCollisions(_ e: Entity) {
                if let m = e as? ModelEntity, m.model != nil, m.isEnabled, !m.name.hasPrefix("anatomy.") {
                    m.generateCollisionShapes(recursive: false); collisionParts += 1
                }
                for c in e.children { addCollisions(c) }
            }
            addCollisions(root)
            hitBody.name = "hitBody"
            if collisionParts == 0 {   // 万一模型结构变了：退回整机盒，至少能点到
                let b = root.visualBounds(relativeTo: nil)
                hitBody.position = b.center
                hitBody.components.set(CollisionComponent(shapes: [.generateBox(size: b.extents)]))
            }
            holder.addChild(hitBody)
            // 生成的內部件另外加：組好時它們都包在外殼裡，不改變原本 87 件的命中；拆開後也點得到
            for m in anatomyGenerated { m.generateCollisionShapes(recursive: false) }
            log("hit test: \(collisionParts) part collision shapes (+\(anatomyGenerated.count) anatomy)")

            // 初始屏幕：先放一块黑，等 PetView 把第一帧脸接进来。
            makeScreenBlack()
            displayLoaded = true
            apply(finish: .starlight)
            log("USDZ loaded (RealityKit)")
        } catch {
            log("USDZ 加载失败：\(error)")
        }
    }

    /// 生成 USDZ 沒有的內部件，再把全部零件分進九層（Anatomy.swift）。
    private func buildAnatomy(base: Entity, screen: Entity) {
        anatomyScreen.name = "anatomy.screen"
        anatomyScreen.position = SIMD3<Float>(0, Float(Self.rigY), 4.28)
        anatomyScreen.orientation = simd_quatf(angle: -Float(Self.tilt), axis: SIMD3<Float>(1, 0, 0))
        screen.addChild(anatomyScreen)
        let f = AnatomyInternals.screenFrame()
        anatomyScreen.addChild(f.root)
        anatomyFrame = f.root
        let b = AnatomyInternals.base()
        for (r, _) in b.radiators { base.addChild(r) }
        base.addChild(b.woofer); base.addChild(b.power)
        anatomyRadiators = b.radiators; anatomyWoofer = b.woofer; anatomyPower = b.power
        for p in f.pieces + b.pieces {
            anatomyParts[ObjectIdentifier(p.entity)] = p.part
            if let m = p.entity as? ModelEntity {
                if !m.name.hasPrefix("anatomy.") { m.name = "anatomy.\(p.part.rawValue)" }
                anatomyGenerated.append(m)
            }
        }
        if let port = usbPort { anatomyParts[ObjectIdentifier(port.root)] = .power }
        buildExplodeMovers()
    }

    /// 這個實體屬於哪一件：自己或祖先在表裡就用它，否則螢幕組歸托盤、底座歸揚聲器模組
    func anatomyPart(of e: Entity) -> AnatomyPart {
        var cur: Entity? = e
        while let c = cur {
            if let p = anatomyParts[ObjectIdentifier(c)] ?? AnatomyPart.usdz[c.name] { return p }
            if c === screenPivot { return .tray }
            if c === baseGroup { return .baseModule }
            cur = c.parent
        }
        return .baseModule
    }

    /// 九層的位移（e=1 時）。螢幕側沿螢幕法線 n 拉開：玻璃最前、托盤往後；底座側：鉸鏈往上、
    /// 輻射器往左右、電源從背面抽出、低音和腳座往下。
    private func buildExplodeMovers() {
        explodeMovers.removeAll()
        guard let screen = screenGroup, let base = baseGroup else { return }
        let n = SIMD3<Float>(0, sinf(Float(Self.tilt)), cosf(Float(Self.tilt)))
        // 鉸鏈上下兩半在拆開後會合：底座那半往上 (0, 4.2, 1.2)，螢幕那半扣掉螢幕組的整體位移
        let hingeBase = SIMD3<Float>(0, 4.2, 1.2)
        let hingeScreen = hingeBase - Self.screenLift
        var seen = Set<ObjectIdentifier>()

        func add(_ e: Entity, _ offset: SIMD3<Float>, _ layer: AnatomyLayer) {
            let key = ObjectIdentifier(e)
            guard !seen.contains(key), e.isEnabled else { return }
            seen.insert(key)
            explodeMovers.append(ExplodeMover(entity: e, origin: e.position, offset: offset, layer: layer))
        }
        func walk(_ e: Entity, _ offset: (AnatomyPart) -> SIMD3<Float>?) {
            if e === anatomyScreen { return }
            if let m = e as? ModelEntity, m.model != nil {
                let part = anatomyPart(of: m)
                if let o = offset(part) { add(e, o, part.layer) }
            }
            for c in e.children { walk(c, offset) }
        }

        walk(screen) { part in
            switch part {
            case .coverGlass: return n * 9.5
            case .display: return n * 6.4
            case .hinge: return hingeScreen
            case .tray: return n * -2.2
            default: return n * 3.0          // 相機等電子框架上的件
            }
        }
        if let frame = anatomyFrame { add(frame, SIMD3<Float>(0, 0, 3.0), .frame) }   // 容器座標的 +z 就是 n
        if let back = screenBack { add(back, n * -2.2, .tray) }

        for child in base.children where child !== usbPort?.root && child !== anatomyPower && child !== anatomyWoofer
            && !anatomyRadiators.contains(where: { $0.0 === child }) {
            walk(child) { part in
                switch part {
                case .hinge: return hingeBase
                case .foot: return SIMD3<Float>(0, -6.0, 0)
                default: return nil          // 圓頂、網罩：底座揚聲器模組，原地不動
                }
            }
        }
        for (r, side) in anatomyRadiators { add(r, SIMD3<Float>(4.6 * side, 0.4, 0), .radiators) }
        let powerOut = SIMD3<Float>(0, -0.8, -3.2)   // 電源從背面抽出來
        if let p = anatomyPower { add(p, powerOut, .baseModule) }
        if let port = usbPort { add(port.root, powerOut, .baseModule) }
        if let w = anatomyWoofer { add(w, SIMD3<Float>(0, -3.6, 0), .woofer) }
    }

    /// 挑零件用的緊貼盒子；第一次用才建（要讀網格頂點）
    private func anatomyPicker() -> AnatomyPicker {
        if let picker { return picker }
        var items: [(entity: ModelEntity, frame: Entity, part: AnatomyPart)] = []
        func walk(_ e: Entity, _ frame: Entity) {
            if let m = e as? ModelEntity, m.model != nil, m.isEnabledInHierarchy {
                items.append((m, frame, anatomyPart(of: m)))
            }
            for c in e.children { walk(c, frame) }
        }
        walk(screenPivot, screenAnchor)
        if let base = baseGroup { walk(base, base) }
        let p = AnatomyPicker(items)
        picker = p
        return p
    }
    /// 射線（世界座標）打到的零件
    func pickAnatomy(origin: SIMD3<Float>, direction: SIMD3<Float>) -> (AnatomyPart, SIMD3<Float>)? {
        anatomyPicker().pick(origin: origin, direction: direction)
    }
    /// 標籤指的位置（世界座標）
    func anatomyAnchor(_ part: AnatomyPart, eye: SIMD3<Float> = SIMD3<Float>(0, 10, 100)) -> SIMD3<Float>? {
        anatomyPicker().anchor(part, eye: eye)
    }
    private func makeScreenBlack() {
        guard let tex = try? TextureResource.generate(from: Self.blackImage(), withName: "screen",
                                                      options: .init(semantic: .color, mipmapsMode: .none)) else { return }
        screenTexture = tex
        screenMaterial.color.texture = MaterialParameters.Texture(tex)
        displayNode?.model?.materials = [screenMaterial]
    }

    private static func blackImage() -> CGImage {
        makeImage(64, 64) { g in
            g.setFillColor(NSColor.black.cgColor)
            g.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }

    /// 脸的 CGImage。尺寸不变时原地替换，避免每帧新建 GPU 纹理。
    /// 只算錶面貼圖的換新次數（材質、外觀換了不算）：海報補丁用來判斷「只有螢幕內容變了」
    private(set) var screenGeneration = 0
    /// 目前螢幕上那張錶面（直播時是 nil）
    private(set) var lastScreenImage: CGImage?
    func setScreen(_ image: CGImage) {
        guard displayLoaded else { return }
        generation += 1
        screenGeneration += 1
        lastScreenImage = image
        if let tex = screenTexture, tex.width == image.width, tex.height == image.height {
            do {
                try tex.replace(withImage: image, options: .init(semantic: .color, mipmapsMode: .none))
                return
            } catch {
                // 尺寸/格式变化时重建
            }
        }
        guard let tex = try? TextureResource.generate(from: image, withName: "screen",
                                                      options: .init(semantic: .color, mipmapsMode: .none)) else { return }
        screenTexture = tex
        screenMaterial.color.texture = MaterialParameters.Texture(tex)
        displayNode?.model?.materials = [screenMaterial]
    }

    /// 直播帧：MTLTexture 零拷贝包成 TextureResource（不经过 CPU）。
    func setScreen(texture: MTLTexture) {
        guard displayLoaded else { return }
        generation += 1
        lastScreenImage = nil
        let tex = TextureResource.__texture(from: texture)
        screenTexture = tex
        screenMaterial.color.texture = MaterialParameters.Texture(tex)
        displayNode?.model?.materials = [screenMaterial]
    }

    /// 铰链：点头/摇头 + 追人的小幅度俯仰/偏航。
    func setRig(pitch: Float, yaw: Float) {
        // 挂墙：没有铰链，屏幕扶正（抵消 USDZ 自带的后仰）后固定不动
        if wall { screenPivot.orientation = simd_quatf(angle: Float(Self.tilt), axis: SIMD3<Float>(1, 0, 0)); return }
        screenPivot.orientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
            * simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
    }

    /// 挂墙模式：藏起底座（圆顶、网罩、脚圈、USB‑C 都在里面）和铰链，只留屏幕模组，直立正对前方。
    private(set) var wall = false
    func setWall(_ on: Bool) {
        wall = on
        baseGroup?.isEnabled = !on
        for name in ["TlTyQAuZSZnkfBS", "UHiMdHobqyuoBpP"] { usdzRoot?.findEntity(named: name)?.isEnabled = !on }   // 铰链上下两半
        setRig(pitch: 0, yaw: 0)
        generation += 1
    }
    /// 挂墙时显示面中心（世界座标，cm）：绕铰链转回直立后的位置，镜头对准这里
    static var wallScreenCenter: SIMD3<Float> {
        let t = Float(tilt), dy = Float(rigY - hingeY), dz = 4.28 - rigHome.z
        return rigHome + SIMD3<Float>(0, dy * cosf(t) - dz * sinf(t), dy * sinf(t) + dz * cosf(t))
    }

    /// 按下时的 2.5% 缩放和 4.5 秒一次的轻微浮动（都以底座底面为原点）。
    func setIdle(press: CGFloat, bob: CGFloat) {
        holder.scale = SIMD3<Float>(repeating: Float(100 * press))
        holder.position.y = Float(bob)
    }

    /// 整机在底座上转向（见 Aim.swift）：窗口位置倾斜＋DockKit 式跟随。值没变就不写 transform。
    private(set) var aimYaw: Float = .nan
    func setAim(yaw: Float) {
        guard aimYaw.isNaN || abs(yaw - aimYaw) > 0.0002 else { return }
        aimYaw = yaw
        holder.orientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
    }

    /// 拆开进度 t（0 组好 … 1 拆开）。
    /// 九層錯開：外層先動、組回時內層先回（AnatomyLayer.progress）。
    func apply(_ t: CGFloat) {
        screenPivot.position = Self.rigHome + Self.screenLift * Float(AnatomyLayer.liftProgress(t))
        for m in explodeMovers { m.entity.position = m.origin + m.offset * Float(m.layer.progress(t)) }
    }

    /// 自检用：当前圆顶材质的金属度（星光/银＝1，G4 白＝0）。
    var selftestMetalness: Double {
        guard let p = bodyParts.first?.entity.model?.materials.first as? PhysicallyBasedMaterial else { return -1 }
        return Double(p.metallic.scale)
    }

    /// 屏幕下沿是一块朝下的平面，和周围曲面的受光不同：
    /// G4 白塑料偏暗，补一点同色环境光；铝色先压暗底色，再用同色微补光收掉接缝处的阴影。
    private static func screenGrille(_ shell: PhysicallyBasedMaterial, for f: Finish) -> PhysicallyBasedMaterial {
        var m = shell
        if f == .g4 {
            m.emissiveColor.__color = NSColor(calibratedWhite: 0.10, alpha: 1).cgColor
        } else if let hex = f.aluminum,
                  let c = srgb(hex).usingColorSpace(.sRGB) {
            let k: CGFloat = 0.95
            m.baseColor.tint = NSColor(srgbRed: c.redComponent * k, green: c.greenComponent * k,
                                       blue: c.blueComponent * k, alpha: 1)
            let e: CGFloat = 0.04
            m.emissiveColor.__color = NSColor(srgbRed: c.redComponent * e, green: c.greenComponent * e,
                                              blue: c.blueComponent * e, alpha: 1).cgColor
        }
        return m
    }

    /// 外观：星光色完全用 USDZ 原材质；其余颜色改外壳 baseColor，保留各件原有金属度/粗糙度/法线。
    /// 网罩用原生 opacity 遮罩切成同色冲孔板，孔后的暖色衬里同时换成中性深色。
    /// G4 白是致敬款：白色亮面塑料。
    func apply(finish f: Finish) {
        finish = f
        generation += 1
        usbPort?.apply(finish: f)
        for part in bodyParts {
            if f == .starlight {
                part.entity.model?.materials = part.materials
                continue
            }
            var mats = part.materials
            for i in mats.indices {
                guard var p = mats[i] as? PhysicallyBasedMaterial else { continue }
                if f == .g4 {
                    p.baseColor.tint = NSColor(calibratedWhite: 0.93, alpha: 1)
                    p.metallic.scale = 0
                    p.roughness.scale = 0.34
                    p.normal.texture = nil
                    p.ambientOcclusion.texture = nil
                    p.clearcoat.scale = 1.0
                    p.clearcoatRoughness.scale = 0.04
                } else if let hex = f.aluminum {
                    p.baseColor.tint = srgb(hex)
                }
                mats[i] = p
            }
            part.entity.model?.materials = mats
        }

        guard f != .starlight else {
            for part in grilleParts { part.entity.model?.materials = part.materials }
            for part in grilleInnerParts { part.entity.model?.materials = part.materials }
            for part in grilleBackingParts { part.entity.model?.materials = part.materials }
            return
        }
        guard let mask = grilleMask else { return }
        let maskTexture = MaterialParameters.Texture(mask)
        let opacity = PhysicallyBasedMaterial.Opacity(scale: 1, texture: maskTexture)

        // 外层：机身的同色金属/塑料，孔洞仍用原生遮罩切出。
        var shell = PhysicallyBasedMaterial()
        if f == .g4 {
            shell.baseColor.tint = NSColor(calibratedWhite: 0.93, alpha: 1)
            shell.metallic.scale = 0
            shell.roughness.scale = 0.34
            shell.clearcoat.scale = 1.0
            shell.clearcoatRoughness.scale = 0.04
        } else if let hex = f.aluminum {
            shell.baseColor.tint = srgb(hex)
            shell.metallic.scale = f == .gray ? 0.75 : 1
            shell.roughness.scale = f == .gray ? 0.78 : 0.70
        } else {
            return
        }
        shell.blending = .transparent(opacity: opacity)
        shell.opacityThreshold = 0.5
        for part in grilleParts {
            if let sg = screenGrillePart, part.entity === sg.entity {
                part.entity.model?.materials = [Self.screenGrille(shell, for: f)]
            } else {
                part.entity.model?.materials = [shell]
            }
        }

        // 内层：孔后的衬里。星光色是暖棕，深色机身下改成中性深灰，避免孔里透出棕色。
        var lining = PhysicallyBasedMaterial()
        lining.baseColor.tint = NSColor(calibratedWhite: 0.04, alpha: 1)
        lining.metallic.scale = 0
        lining.roughness.scale = 1.0
        lining.blending = .transparent(opacity: opacity)
        lining.opacityThreshold = 0.5
        for part in grilleInnerParts { part.entity.model?.materials = [lining] }

        // 再后面是实心衬底：不改的话，孔里会透出 USDZ 的暖灰色，深色机身下像一圈铜色。
        var backing = PhysicallyBasedMaterial()
        backing.baseColor.tint = NSColor(calibratedWhite: 0.055, alpha: 1)
        backing.metallic.scale = 0
        backing.roughness.scale = 1.0
        for part in grilleBackingParts { part.entity.model?.materials = [backing] }
    }
}
