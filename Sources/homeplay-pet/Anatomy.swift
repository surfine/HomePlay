import AppKit
import RealityKit
import simd

// 「拆開看看」的真實構造（體驗改善計劃 §七）。
// 依據：Apple 規格頁 apple.com/apple-homeview/specs/（A18、7 吋 1088×1088 IPS、12MP Center Stage、
// 四顆麥克風前／左／右／後、顯示器內兩顆全音域、底座朝下低音＋兩顆對置被動輻射器、Wi‑Fi 6E／藍牙 6.0／Thread、
// 環境光／溫濕度／加速度計、USB‑C 30W）。FCC 內部照片要到出貨約 180 天後才公開，屆時再校正內部件的位置。
// 九層照 homeview-anatomy.vercel.app 由外而內：蓋板玻璃、面板、電子框架、顯示托盤、鉸鏈、被動輻射器、
// 底座揚聲器模組、低音單體、腳座。USDZ 沒有的內部件（主機板、無線、麥克風、全音域、輻射器、低音、電源）
// 用簡單網格生成，單位與 USDZ 群組空間相同：公分。

/// 九層，由外而內；拆開時外層先動，組回時內層先回。
enum AnatomyLayer: Int, CaseIterable {
    case coverGlass, display, frame, tray, hinge, radiators, baseModule, woofer, foot

    /// 每層的展開時間窗：起點錯開 0.06，各走 0.46（最後一層在 t≈0.94 到位）。
    static let stagger: CGFloat = 0.06, span: CGFloat = 0.46
    func progress(_ t: CGFloat) -> CGFloat {
        ease(clamp01((t - CGFloat(rawValue) * Self.stagger) / Self.span))
    }
    /// 螢幕組整體離開底座：和第一層同時起步
    static func liftProgress(_ t: CGFloat) -> CGFloat { ease(clamp01(t / span)) }
}

/// 滑過／點到時能叫出名字的零件。一層裡可以有幾件（電子框架上有主機板、相機、麥克風…）。
enum AnatomyPart: String, CaseIterable {
    case coverGlass, display, frame, logicBoard, radios, camera, ambientLight, microphones, fullRange,
         tray, hinge, radiators, baseModule, power, climate, woofer, foot

    var layer: AnatomyLayer {
        switch self {
        case .coverGlass: return .coverGlass
        case .display: return .display
        case .frame, .logicBoard, .radios, .camera, .ambientLight, .microphones, .fullRange: return .frame
        case .tray: return .tray
        case .hinge: return .hinge
        case .radiators: return .radiators
        case .baseModule, .power, .climate: return .baseModule
        case .woofer: return .woofer
        case .foot: return .foot
        }
    }

    var title: String {
        switch self {
        case .coverGlass: return L("anatomy.coverGlass", "盖板玻璃")
        case .display: return L("anatomy.display", "显示面板")
        case .frame: return L("anatomy.frame", "电子框架")
        case .logicBoard: return L("anatomy.logicBoard", "A18 主板")
        case .radios: return L("anatomy.radios", "无线模块与天线")
        case .camera: return L("anatomy.camera", "Center Stage 相机")
        case .ambientLight: return L("anatomy.ambientLight", "环境光传感器")
        case .microphones: return L("anatomy.microphones", "麦克风")
        case .fullRange: return L("anatomy.fullRange", "全音域单元")
        case .tray: return L("anatomy.tray", "显示托盘")
        case .hinge: return L("anatomy.hinge", "不锈钢铰链")
        case .radiators: return L("anatomy.radiators", "被动辐射器")
        case .baseModule: return L("anatomy.baseModule", "底座扬声器模组")
        case .power: return L("anatomy.power", "USB-C 电源")
        case .climate: return L("anatomy.climate", "温湿度传感器")
        case .woofer: return L("anatomy.woofer", "低音单元")
        case .foot: return L("anatomy.foot", "底脚")
        }
    }

    /// 一句規格，取自 Apple 規格頁
    var spec: String {
        switch self {
        case .coverGlass: return L("anatomy.coverGlass.spec", "覆盖整块显示屏，上缘留相机开孔")
        case .display: return L("anatomy.display.spec", "7 英寸 IPS 显示屏，1088×1088 像素")
        case .frame: return L("anatomy.frame.spec", "承载主板、相机、麦克风与两个全音域单元")
        case .logicBoard: return L("anatomy.logicBoard.spec", "A18 芯片，内建神经网络引擎；含加速度计")
        case .radios: return L("anatomy.radios.spec", "Wi-Fi 6E、蓝牙 6.0、Thread")
        case .camera: return L("anatomy.camera.spec", "1200 万像素，人物居中（Center Stage）")
        case .ambientLight: return L("anatomy.ambientLight.spec", "按环境光自动调整屏幕亮度")
        case .microphones: return L("anatomy.microphones.spec", "四个麦克风：前、左、右、后")
        case .fullRange: return L("anatomy.fullRange.spec", "显示器内两个全音域扬声器单元")
        case .tray: return L("anatomy.tray.spec", "铝金属背壳，托住整块显示器")
        case .hinge: return L("anatomy.hinge.spec", "不锈钢，连接显示器与铝圆顶底座")
        case .radiators: return L("anatomy.radiators.spec", "两个对置，互相抵消振动、加强低频")
        case .baseModule: return L("anatomy.baseModule.spec", "铝圆顶与网罩包住扬声器腔体")
        case .power: return L("anatomy.power.spec", "USB-C 接口，30W 电源适配器")
        case .climate: return L("anatomy.climate.spec", "感测室内温度与湿度")
        case .woofer: return L("anatomy.woofer.spec", "朝下发声的低音扬声器")
        case .foot: return L("anatomy.foot.spec", "底座最下面一圈，稳住整机")
        }
    }

    /// 自動導覽的順序：由外而內
    static let tourOrder: [AnatomyPart] = [
        .coverGlass, .display, .camera, .ambientLight, .microphones, .logicBoard, .radios, .fullRange, .frame,
        .tray, .hinge, .radiators, .baseModule, .power, .climate, .woofer, .foot,
    ]

    /// USDZ 零件（節點名）對應到哪一件；沒列出的：螢幕組歸托盤，底座歸揚聲器模組。
    static let usdz: [String: AnatomyPart] = [
        "gBXWwTbBvrZBZxY": .coverGlass, "CQYxVMMBqQxFika": .coverGlass, "QGllJRESAsAqZbr": .coverGlass,
        "RFkcSjAtJLGqwDA": .display,
        "dnWBtCgXgURnMfA": .camera, "oINzDReSCgetOOm": .camera, "TkUCHirvrDVQZGP": .camera,
        "TlTyQAuZSZnkfBS": .hinge, "UHiMdHobqyuoBpP": .hinge,
        "nLuFOBqijsErMHq": .foot,
    ]
}

// MARK: - 生成的內部件

/// USDZ 沒有的內部件。螢幕側的件放在「螢幕座標」容器裡（原點＝顯示面中心，+z＝螢幕法線，+y＝沿螢幕往上），
/// 底座側直接用底座群組空間。全部是公分。
enum AnatomyInternals {
    struct Piece { let entity: Entity; let part: AnatomyPart }

    /// 螢幕側：電子框架層（框架板、主機板與 A18、無線、相機旁的環境光、四顆麥克風、兩顆全音域）。
    /// 回傳的 root 要加到螢幕座標容器下，整個作為電子框架層移動。
    static func screenFrame() -> (root: Entity, pieces: [Piece]) {
        let root = Entity()
        root.name = "anatomy.frame"
        var pieces: [Piece] = []
        func add(_ e: Entity, _ p: AnatomyPart) { root.addChild(e); pieces.append(Piece(entity: e, part: p)) }

        // 框架板：比背殼小一圈，貼在背殼內側
        add(box("frame.plate", 13.0, 12.2, 0.08, at: [0, 0, -0.80], metal(0x8d9095, rough: 0.45)), .frame)
        // 主機板＋A18＋周邊晶片（加速度計在主機板上）
        add(box("board", 8.2, 5.6, 0.10, at: [0.6, 1.0, -0.70], pbr(0x1f3a2d, rough: 0.55)), .logicBoard)
        add(box("a18", 1.45, 1.45, 0.12, at: [1.5, 1.4, -0.59], metal(0xb9bcc1, rough: 0.32)), .logicBoard)
        add(box("dram", 1.1, 0.8, 0.09, at: [3.3, 1.6, -0.60], pbr(0x26272a, rough: 0.4)), .logicBoard)
        add(box("pmic", 0.9, 0.9, 0.08, at: [3.4, 0.0, -0.61], pbr(0x26272a, rough: 0.4)), .logicBoard)
        add(box("accel", 0.3, 0.3, 0.06, at: [-0.6, -0.9, -0.62], pbr(0x26272a, rough: 0.4)), .logicBoard)
        // 無線：屏蔽罩＋上緣兩條天線軟板＋右緣一條
        add(box("radio.shield", 1.9, 1.3, 0.14, at: [-2.2, 2.6, -0.58], metal(0xc7cacf, rough: 0.38)), .radios)
        add(box("antenna.l", 2.4, 0.4, 0.04, at: [-4.6, 5.7, -0.72], pbr(0xc4873a, rough: 0.5)), .radios)
        add(box("antenna.r", 2.4, 0.4, 0.04, at: [4.6, 5.7, -0.72], pbr(0xc4873a, rough: 0.5)), .radios)
        add(box("antenna.side", 0.4, 2.4, 0.04, at: [6.1, -1.6, -0.72], pbr(0xc4873a, rough: 0.5)), .radios)
        // 相機旁的環境光感測器
        add(box("als", 0.36, 0.22, 0.08, at: [-1.4, 6.75, -0.12], pbr(0x0b0b0c, rough: 0.15)), .ambientLight)
        // 四顆麥克風：前（上緣、相機右邊）、左、右（左右側緣）、後（背面）
        let micMesh = lathe([(0, -0.06), (0.16, -0.06), (0.16, 0.06), (0, 0.06)])
        let micMat = pbr(0x141415, rough: 0.5)
        for (name, pos, axis) in [("mic.front", SIMD3<Float>(1.5, 6.75, -0.14), SIMD3<Float>(0, 0, 1)),
                                  ("mic.left", [-6.9, 2.4, -0.5], [-1, 0, 0]),
                                  ("mic.right", [6.9, 2.4, -0.5], [1, 0, 0]),
                                  ("mic.back", [0, 4.4, -0.86], [0, 0, -1])] as [(String, SIMD3<Float>, SIMD3<Float>)] {
            let m = ModelEntity(mesh: micMesh, materials: [micMat])
            m.name = "anatomy." + name
            m.position = pos
            m.orientation = simd_quatf(from: [0, 1, 0], to: axis)
            add(m, .microphones)
        }
        // 兩顆全音域：在下緣網罩後面，朝下出聲
        for x: Float in [-3.3, 3.3] {
            add(box("fullrange.body", 3.8, 0.75, 0.55, at: [x, -6.15, -0.47], pbr(0x2b2c2f, rough: 0.6), corner: 0.2), .fullRange)
            add(box("fullrange.cone", 3.2, 0.04, 0.38, at: [x, -6.54, -0.47], pbr(0x161617, rough: 0.8)), .fullRange)
        }
        return (root, pieces)
    }

    /// 底座側：兩顆對置被動輻射器（左右各一）、朝下低音、電源（USB‑C 後的小板＋往上的軟排線＋溫濕度感測器）。
    static func base() -> (radiators: [(Entity, Float)], woofer: Entity, power: Entity, pieces: [Piece]) {
        var pieces: [Piece] = []
        // 被動輻射器：鋁色振膜＋深色懸邊；軸朝 ±x
        let diaphragm = lathe([(0, -0.09), (1.75, -0.09), (1.75, 0.09), (0, 0.09)])
        let surround = lathe([(1.6, -0.05), (2.05, -0.05), (2.05, 0.05), (1.6, 0.05)])
        var radiators: [(Entity, Float)] = []
        for side: Float in [-1, 1] {
            let r = Entity()
            r.name = side < 0 ? "anatomy.radiator.left" : "anatomy.radiator.right"
            r.position = [3.15 * side, 4.3, 0]
            r.orientation = simd_quatf(from: [0, 1, 0], to: [side, 0, 0])
            let d = ModelEntity(mesh: diaphragm, materials: [metal(0x7d8188, rough: 0.5)])
            let s = ModelEntity(mesh: surround, materials: [pbr(0x1e1e20, rough: 0.85)])
            r.addChild(d); r.addChild(s)
            pieces += [Piece(entity: d, part: .radiators), Piece(entity: s, part: .radiators)]
            radiators.append((r, side))
        }
        // 低音：紙盆朝下，磁鐵在上
        let woofer = Entity()
        woofer.name = "anatomy.woofer"
        let cone = ModelEntity(mesh: lathe([(0, 0.95), (0.9, 1.05), (2.7, 0.62), (3.0, 0.56), (3.05, 0.66), (0.9, 1.12), (0, 1.02)]),
                               materials: [pbr(0x1c1c1e, rough: 0.9)])
        let basket = ModelEntity(mesh: lathe([(2.95, 0.6), (3.05, 0.6), (3.05, 0.9), (1.45, 1.5), (1.4, 2.25), (0, 2.25), (0, 1.5), (1.3, 1.45), (2.95, 0.85)]),
                                 materials: [metal(0x55575b, rough: 0.5)])
        woofer.addChild(cone); woofer.addChild(basket)
        pieces += [Piece(entity: cone, part: .woofer), Piece(entity: basket, part: .woofer)]
        // 電源：USB‑C 母座後面的小板、往上接鉸鏈的軟排線、板上的溫濕度感測器
        let power = Entity()
        power.name = "anatomy.power"
        let board = box("power.board", 2.6, 1.3, 0.08, at: [0, 1.6, -3.55], pbr(0x1f3a2d, rough: 0.55))
        let flex = box("power.flex", 0.5, 3.8, 0.04, at: [0, 4.0, -3.2], pbr(0xc4873a, rough: 0.5))
        let climate = box("climate", 0.32, 0.32, 0.07, at: [0.85, 1.6, -3.47], pbr(0xe8e8ea, rough: 0.4))
        power.addChild(board); power.addChild(flex); power.addChild(climate)
        pieces += [Piece(entity: board, part: .power), Piece(entity: flex, part: .power), Piece(entity: climate, part: .climate)]
        return (radiators, woofer, power, pieces)
    }

    // MARK: 網格與材質

    private static func box(_ name: String, _ w: Float, _ h: Float, _ d: Float, at p: SIMD3<Float>,
                            _ m: PhysicallyBasedMaterial, corner: Float = 0) -> ModelEntity {
        let e = ModelEntity(mesh: .generateBox(width: w, height: h, depth: d, cornerRadius: corner), materials: [m])
        e.name = "anatomy." + name
        e.position = p
        return e
    }
    private static func pbr(_ hex: UInt32, rough: Float) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor.tint = srgb(hex)
        m.roughness.scale = rough
        m.metallic.scale = 0
        m.faceCulling = .none
        return m
    }
    private static func metal(_ hex: UInt32, rough: Float) -> PhysicallyBasedMaterial {
        var m = pbr(hex, rough: rough)
        m.metallic.scale = 1
        return m
    }

    /// 旋轉體：輪廓 (r, y) 繞 Y 軸轉一圈。輪廓由下往上走時，(dy, -dr) 是朝外的法線。
    /// 沿輪廓每段各自一條帶（法線不跨段平均），所以邊角是硬的。
    static func lathe(_ profile: [(Float, Float)], segments: Int = 40) -> MeshResource {
        var pos: [SIMD3<Float>] = [], nor: [SIMD3<Float>] = [], idx: [UInt32] = []
        for i in 0..<(profile.count - 1) {
            let (r0, y0) = profile[i], (r1, y1) = profile[i + 1]
            let len = max(1e-6, hypot(r1 - r0, y1 - y0))
            let nr = (y1 - y0) / len, ny = -(r1 - r0) / len
            let base = UInt32(pos.count)
            for s in 0...segments {
                let a = Float(s) / Float(segments) * 2 * .pi
                let c = cos(a), sn = sin(a)
                pos.append([r0 * c, y0, r0 * sn]); pos.append([r1 * c, y1, r1 * sn])
                let n = simd_normalize(SIMD3<Float>(nr * c, ny, nr * sn))
                nor.append(n); nor.append(n)
            }
            for s in 0..<UInt32(segments) {
                let a = base + s * 2, b = a + 1, c = a + 3, d = a + 2
                idx += [a, b, c, a, c, d]
            }
        }
        var desc = MeshDescriptor()
        desc.positions = MeshBuffer(pos)
        desc.normals = MeshBuffer(nor)
        desc.primitives = .triangles(idx)
        return (try? MeshResource.generate(from: [desc])) ?? .generateBox(size: 0.1)
    }
}

// MARK: - 挑零件

/// 滑鼠點到的是哪一件。不用 RealityKit 的碰撞盒（那是群組軸向的 AABB，螢幕後仰 20° 後厚了好幾倍，
/// 從正面滑過永遠先打到玻璃的盒子），改成每件在自己的參考座標裡算一次緊貼的盒子：
/// 螢幕側用螢幕座標（跟著後仰），底座側用底座群組。拆開只做平移，盒子跟著件的位移走。
final class AnatomyPicker {
    private struct Target {
        let entity: Entity
        let frame: Entity
        let part: AnatomyPart
        let box: BoundingBox          // 組好時、在 frame 座標裡
        let origin: SIMD3<Float>      // 組好時件原點在 frame 座標裡的位置
    }
    private var targets: [Target] = []

    /// 必須在組好（t=0）的狀態下建
    init(_ items: [(entity: ModelEntity, frame: Entity, part: AnatomyPart)]) {
        for it in items {
            guard let mesh = it.entity.model?.mesh else { continue }
            let m = it.entity.transformMatrix(relativeTo: it.frame)
            var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
            let contents = mesh.contents
            for inst in contents.instances {
                guard let model = contents.models[inst.model] else { continue }
                let mm = m * inst.transform
                for part in model.parts {
                    for v in part.positions {
                        let p = mm * SIMD4<Float>(v, 1)
                        let q = SIMD3<Float>(p.x, p.y, p.z)
                        lo = simd_min(lo, q); hi = simd_max(hi, q)
                    }
                }
            }
            guard lo.x.isFinite else { continue }
            targets.append(Target(entity: it.entity, frame: it.frame, part: it.part,
                                  box: BoundingBox(min: lo, max: hi),
                                  origin: it.entity.position(relativeTo: it.frame)))
        }
    }
    var count: Int { targets.count }

    private func currentBox(_ t: Target) -> BoundingBox {
        let d = t.entity.position(relativeTo: t.frame) - t.origin
        return BoundingBox(min: t.box.min + d, max: t.box.max + d)
    }

    /// 射線（世界座標）打到最近的那件；回傳件與命中點（世界座標）
    func pick(origin o: SIMD3<Float>, direction dir: SIMD3<Float>) -> (AnatomyPart, SIMD3<Float>)? {
        var best: (Float, AnatomyPart, SIMD3<Float>)?
        for t in targets where t.entity.isEnabledInHierarchy {
            let lo = t.frame.convert(position: o, from: nil)
            let ld = t.frame.convert(direction: dir, from: nil)
            let b = currentBox(t)
            var t0: Float = 0, t1 = Float.infinity
            var hit = true
            for k in 0..<3 {
                if abs(ld[k]) < 1e-9 {
                    if lo[k] < b.min[k] || lo[k] > b.max[k] { hit = false; break }
                    continue
                }
                var a = (b.min[k] - lo[k]) / ld[k], c = (b.max[k] - lo[k]) / ld[k]
                if a > c { swap(&a, &c) }
                t0 = max(t0, a); t1 = min(t1, c)
                if t0 > t1 { hit = false; break }
            }
            guard hit else { continue }
            // 參數 t 在各 frame 裡的尺度不同：換回世界距離再比
            let wp = t.frame.convert(position: lo + ld * t0, to: nil)
            let dist = simd_length(wp - o)
            if best == nil || dist < best!.0 { best = (dist, t.part, wp) }
        }
        return best.map { ($0.1, $0.2) }
    }

    /// 標籤要指的位置（世界座標）：件分散幾處（鉸鏈上下兩半、左右輻射器、四顆麥克風）時，
    /// 在夠大的幾塊（≥ 最大那塊的八成）裡取離鏡頭最近的，指線才不會指到背面或空中。
    func anchor(_ part: AnatomyPart, eye: SIMD3<Float>) -> SIMD3<Float>? {
        var blocks: [(size: Float, center: SIMD3<Float>)] = []
        for t in targets where t.part == part && t.entity.isEnabledInHierarchy {
            let b = currentBox(t)
            blocks.append((simd_length(b.extents), t.frame.convert(position: b.center, to: nil)))
        }
        guard let biggest = blocks.map(\.size).max() else { return nil }
        return blocks.filter { $0.size >= biggest * 0.8 }
            .min { simd_distance($0.center, eye) < simd_distance($1.center, eye) }?.center
    }
}

// MARK: - 標籤

/// 指著零件的標籤：圓點＋指線＋名稱與一句規格。深淺色跟系統外觀；不接滑鼠事件。
final class AnatomyCallout: NSView {
    var part: AnatomyPart? { didSet { if part != oldValue { needsDisplay = true } } }
    var anchor: CGPoint = .zero { didSet { if anchor != oldValue { needsDisplay = true } } }
    var opacity: CGFloat = 1 { didSet { if abs(opacity - oldValue) > 0.01 { needsDisplay = true } } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    private var dark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    override func draw(_ dirtyRect: NSRect) {
        guard let part, opacity > 0.01, let g = NSGraphicsContext.current?.cgContext else { return }
        let dark = self.dark
        let s = max(0.75, min(1.2, bounds.width / 480))
        let titleFont = NSFont.systemFont(ofSize: 13 * s, weight: .semibold)
        let specFont = NSFont.systemFont(ofSize: 11 * s, weight: .regular)
        let ink = dark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.08, alpha: 1)
        let sub = dark ? NSColor(white: 0.72, alpha: 1) : NSColor(white: 0.36, alpha: 1)
        let fill = dark ? NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 0.94)
                        : NSColor(white: 1, alpha: 0.95)
        let stroke = dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.10)
        let accent = dark ? NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)
                          : NSColor(srgbRed: 0, green: 0.44, blue: 0.89, alpha: 1)

        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byWordWrapping
        let title = NSAttributedString(string: part.title, attributes: [.font: titleFont, .foregroundColor: ink, .paragraphStyle: para])
        let spec = NSAttributedString(string: part.spec, attributes: [.font: specFont, .foregroundColor: sub, .paragraphStyle: para])
        let pad = 9 * s, gap = 2 * s
        let maxText = max(150 * s, min(250 * s, bounds.width * 0.5))
        let tr = title.boundingRect(with: NSSize(width: maxText, height: 200), options: [.usesLineFragmentOrigin])
        let sr = spec.boundingRect(with: NSSize(width: maxText, height: 200), options: [.usesLineFragmentOrigin])
        let w = ceil(max(tr.width, sr.width)) + pad * 2
        let h = ceil(tr.height) + gap + ceil(sr.height) + pad * 2

        // 標籤放在錨點外側（錨點在左半先試右邊），垂直對齊錨點；兩側都放不下就放到錨點上方或下方。
        // 卡片永遠不蓋住錨點。
        let margin = 8 * s, reach = 30 * s
        let rightX = anchor.x + reach, leftX = anchor.x - reach - w
        let fitsRight = rightX + w <= bounds.width - margin, fitsLeft = leftX >= margin
        var x: CGFloat, y: CGFloat
        enum Side { case right, left, above, below }
        let side: Side
        if anchor.x < bounds.midX ? fitsRight : !fitsLeft && fitsRight {
            side = .right; x = rightX
        } else if fitsLeft {
            side = .left; x = leftX
        } else {
            x = max(margin, min(bounds.width - margin - w, anchor.x - w / 2))
            side = anchor.y + reach + h <= bounds.height - margin ? .above : .below
        }
        switch side {
        case .right, .left: y = max(margin, min(bounds.height - margin - h, anchor.y - h / 2))
        case .above: y = anchor.y + reach
        case .below: y = max(margin, anchor.y - reach - h)
        }
        let rect = NSRect(x: x, y: y, width: w, height: h)

        g.saveGState()
        g.setAlpha(opacity)
        // 指線：錨點 → 標籤最近的一邊
        let edge: CGPoint
        switch side {
        case .right: edge = CGPoint(x: rect.minX, y: max(rect.minY + 6 * s, min(rect.maxY - 6 * s, anchor.y)))
        case .left: edge = CGPoint(x: rect.maxX, y: max(rect.minY + 6 * s, min(rect.maxY - 6 * s, anchor.y)))
        case .above: edge = CGPoint(x: max(rect.minX + 8 * s, min(rect.maxX - 8 * s, anchor.x)), y: rect.minY)
        case .below: edge = CGPoint(x: max(rect.minX + 8 * s, min(rect.maxX - 8 * s, anchor.x)), y: rect.maxY)
        }
        g.setStrokeColor(accent.cgColor); g.setLineWidth(1.2 * s)
        g.move(to: anchor); g.addLine(to: edge); g.strokePath()
        // 錨點：實心點＋一圈底色描邊，深淺背景上都看得見
        let r = 3.6 * s
        g.setFillColor(fill.cgColor)
        g.fillEllipse(in: CGRect(x: anchor.x - r - 1.5 * s, y: anchor.y - r - 1.5 * s, width: (r + 1.5 * s) * 2, height: (r + 1.5 * s) * 2))
        g.setFillColor(accent.cgColor)
        g.fillEllipse(in: CGRect(x: anchor.x - r, y: anchor.y - r, width: r * 2, height: r * 2))
        // 卡片
        let path = CGPath(roundedRect: rect, cornerWidth: 8 * s, cornerHeight: 8 * s, transform: nil)
        g.setShadow(offset: CGSize(width: 0, height: -1.5 * s), blur: 8 * s, color: NSColor(white: 0, alpha: dark ? 0.45 : 0.18).cgColor)
        g.addPath(path); g.setFillColor(fill.cgColor); g.fillPath()
        g.setShadow(offset: .zero, blur: 0, color: nil)
        g.addPath(path); g.setStrokeColor(stroke.cgColor); g.setLineWidth(0.8); g.strokePath()
        g.restoreGState()

        NSGraphicsContext.current?.saveGraphicsState()
        g.setAlpha(opacity)
        spec.draw(with: NSRect(x: x + pad, y: y + pad, width: maxText, height: ceil(sr.height)), options: [.usesLineFragmentOrigin])
        title.draw(with: NSRect(x: x + pad, y: y + pad + ceil(sr.height) + gap, width: maxText, height: ceil(tr.height)), options: [.usesLineFragmentOrigin])
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
