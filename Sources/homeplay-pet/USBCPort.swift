import AppKit
import RealityKit
import simd

/// HomeView 背面的 USB-C 母座。
/// 开口按 USB-C 规范：8.4 × 2.6 mm，圆角；内部有黑色衬腔、中央金属舌片和上下各 12 个触点。
/// 端口沉在原生凹槽里，不覆盖格栅。
final class USBCPortAssembly {
    let root = Entity()
    private let ring = ModelEntity()

    // 以托面为 z=0，向机身内部 +z 延伸；面的朝向是 -z。
    private static let mouthW: Float = 0.84
    private static let mouthH: Float = 0.26
    private static let mouthR: Float = 0.060
    init() {
        root.name = "usbCPort"

        var ringMaterial = PhysicallyBasedMaterial()
        ringMaterial.baseColor.tint = srgb(0xa79d8b)
        ringMaterial.metallic.scale = 0.70
        ringMaterial.roughness.scale = 0.82
        ringMaterial.faceCulling = .none
        ring.model = ModelComponent(mesh: Self.ringMesh(), materials: [ringMaterial])
        root.addChild(ring)

        // 黑色衬腔：比托面孔略小，露出约 0.4 mm 的黑色密封圈。
        var cavityMat = PhysicallyBasedMaterial()
        cavityMat.baseColor.tint = NSColor(calibratedWhite: 0.030, alpha: 1)
        cavityMat.metallic.scale = 0.8
        cavityMat.roughness.scale = 0.38
        cavityMat.faceCulling = .none
        let cavity = ModelEntity(mesh: Self.ringMesh(
            outerW: Self.mouthW - 0.006, outerH: Self.mouthH - 0.006, outerR: Self.mouthR - 0.003,
            innerW: 0.78, innerH: 0.20, innerR: 0.045, depth: 0.11), materials: [cavityMat])
        cavity.position.z = 0.012
        root.addChild(cavity)

        var backMat = PhysicallyBasedMaterial()
        backMat.baseColor.tint = NSColor(calibratedWhite: 0.006, alpha: 1)
        backMat.metallic.scale = 0.3
        backMat.roughness.scale = 0.65
        let back = ModelEntity(mesh: .generateBox(width: 0.86, height: 0.26, depth: 0.014, cornerRadius: 0.02),
                               materials: [backMat])
        back.position = SIMD3<Float>(0, 0, 0.112)
        root.addChild(back)

        // 中央舌片。USB-C 舌片约 6.5 mm 宽、0.7 mm 厚；前缘留 0.08 mm 倒角。
        var tongueMat = PhysicallyBasedMaterial()
        tongueMat.baseColor.tint = NSColor(calibratedWhite: 0.58, alpha: 1)
        tongueMat.metallic.scale = 1
        tongueMat.roughness.scale = 0.26
        let tongue = ModelEntity(
            mesh: .generateBox(width: 0.66, height: 0.07, depth: 0.11, cornerRadius: 0.008),
            materials: [tongueMat])
        tongue.position = SIMD3<Float>(0, 0, 0.090)
        root.addChild(tongue)

        // 上下各 12 个镀金触点，0.5 mm 间距。
        var gold = PhysicallyBasedMaterial()
        gold.baseColor.tint = srgb(0xb9923f)
        gold.metallic.scale = 1
        gold.roughness.scale = 0.16
        let padMesh = MeshResource.generateBox(width: 0.028, height: 0.002, depth: 0.060)
        for i in 0..<12 {
            let x = -0.275 + Float(i) * 0.05
            for y in [Float(0.037), -0.037] {
                let pad = ModelEntity(mesh: padMesh, materials: [gold])
                pad.position = SIMD3<Float>(x, y, 0.090)
                root.addChild(pad)
            }
        }
    }

    /// 托面跟格栅同色；比纯机身色略暗，补上格栅孔洞造成的整体明度差。
    func apply(finish f: Finish) {
        var m = PhysicallyBasedMaterial()
        if f == .g4 {
            m.baseColor.tint = NSColor(calibratedWhite: 0.93, alpha: 1)
            m.metallic.scale = 0
            m.roughness.scale = 0.34
            m.clearcoat.scale = 1
            m.clearcoatRoughness.scale = 0.04
        } else if let hex = f.aluminum {
            m.baseColor.tint = srgb(hex)
            m.metallic.scale = 1
            m.roughness.scale = 0.50
        } else {
            m.baseColor.tint = srgb(0xd0c3ae)
            m.metallic.scale = 1
            m.roughness.scale = 0.50
        }
        m.faceCulling = .none
        ring.model?.materials = [m]
    }

    private static func ringMesh() -> MeshResource {
        ringMesh(outerW: 0.98, outerH: 0.34, outerR: 0.08,
                 innerW: mouthW, innerH: mouthH, innerR: mouthR, depth: 0.045,
                 includeBack: true, includeSides: true)
    }

    /// 圆角矩形环挤出。外轮廓和内轮廓使用同样多的采样点，生成前/后环面和内外侧壁。
    private static func ringMesh(outerW: Float, outerH: Float, outerR: Float,
                                 innerW: Float, innerH: Float, innerR: Float,
                                 depth: Float, segments: Int = 8, includeBack: Bool = true,
                                 includeSides: Bool = true) -> MeshResource {
        let outer = roundedRect(outerW, outerH, outerR, segments: segments)
        let inner = roundedRect(innerW, innerH, innerR, segments: segments)
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        func add(_ p: SIMD3<Float>, _ n: SIMD3<Float>) -> UInt32 {
            let i = UInt32(positions.count)
            positions.append(p); normals.append(n)
            uvs.append(SIMD2<Float>(p.x / outerW + 0.5, p.y / outerH + 0.5))
            return i
        }

        // 前面（朝外，-z）
        for i in 0..<outer.count {
            let j = (i + 1) % outer.count
            let a = add(SIMD3<Float>(outer[i].x, outer[i].y, 0), SIMD3(0, 0, -1))
            let b = add(SIMD3<Float>(outer[j].x, outer[j].y, 0), SIMD3(0, 0, -1))
            let c = add(SIMD3<Float>(inner[j].x, inner[j].y, 0), SIMD3(0, 0, -1))
            let d = add(SIMD3<Float>(inner[i].x, inner[i].y, 0), SIMD3(0, 0, -1))
            indices += [a, b, c, a, c, d]
        }
        // 背面（托面不需要；否则会从孔里看到自己的背板）
        if includeBack {
            for i in 0..<outer.count {
                let j = (i + 1) % outer.count
                let a = add(SIMD3<Float>(outer[i].x, outer[i].y, depth), SIMD3(0, 0, 1))
                let b = add(SIMD3<Float>(outer[j].x, outer[j].y, depth), SIMD3(0, 0, 1))
                let c = add(SIMD3<Float>(inner[j].x, inner[j].y, depth), SIMD3(0, 0, 1))
                let d = add(SIMD3<Float>(inner[i].x, inner[i].y, depth), SIMD3(0, 0, 1))
                indices += [a, b, c, a, c, d]
            }
        }
        // 外侧壁
        if includeSides {
        for i in 0..<outer.count {
            let j = (i + 1) % outer.count
            let edge = outer[j] - outer[i]
            let n = normalize(SIMD3<Float>(edge.y, -edge.x, 0))
            let a = add(SIMD3<Float>(outer[i].x, outer[i].y, 0), n)
            let b = add(SIMD3<Float>(outer[j].x, outer[j].y, 0), n)
            let c = add(SIMD3<Float>(outer[j].x, outer[j].y, depth), n)
            let d = add(SIMD3<Float>(outer[i].x, outer[i].y, depth), n)
            indices += [a, b, c, a, c, d]
        }
        }
        // 内侧壁（朝孔内）
        if includeSides {
        for i in 0..<inner.count {
            let j = (i + 1) % inner.count
            let edge = inner[j] - inner[i]
            let n = normalize(SIMD3<Float>(-edge.y, edge.x, 0))
            let a = add(SIMD3<Float>(inner[i].x, inner[i].y, 0), n)
            let b = add(SIMD3<Float>(inner[j].x, inner[j].y, 0), n)
            let c = add(SIMD3<Float>(inner[j].x, inner[j].y, depth), n)
            let d = add(SIMD3<Float>(inner[i].x, inner[i].y, depth), n)
            indices += [a, b, c, a, c, d]
        }
        }

        var d = MeshDescriptor()
        d.positions = MeshBuffer(positions)
        d.normals = MeshBuffer(normals)
        d.textureCoordinates = MeshBuffer(uvs)
        d.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [d])) ?? MeshResource.generateBox(width: outerW, height: outerH, depth: depth)
    }

    /// 逆时针圆角矩形轮廓；四分之一圆用 segments 段近似。
    private static func roundedRect(_ w: Float, _ h: Float, _ r: Float, segments: Int) -> [SIMD2<Float>] {
        let radius = max(0.0001, min(r, min(w, h) / 2))
        let cx = max(0, w / 2 - radius), cy = max(0, h / 2 - radius)
        let corners: [(Float, Float, Float, Float)] = [
            (cx, -cy, -.pi / 2, 0),          // 右下
            (cx, cy, 0, .pi / 2),            // 右上
            (-cx, cy, .pi / 2, .pi),         // 左上
            (-cx, -cy, .pi, 3 * .pi / 2),    // 左下
        ]
        var pts: [SIMD2<Float>] = []
        for (ox, oy, a0, a1) in corners {
            for i in 0...segments {
                let a = a0 + (a1 - a0) * Float(i) / Float(segments)
                pts.append(SIMD2(ox + radius * cos(a), oy + radius * sin(a)))
            }
        }
        return pts
    }
}
