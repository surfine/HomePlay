// 2.0 device：真機四色改用 apple-homeview.usdz 自帶的 Color 變體。
//
// Apple 的 Quick Look 資產本來就有四個 Color 變體（Rose_Pink、Silver、Space_Gray、Starlight，預設 Starlight），
// 每個變體換的是 Apple 自己調好的材質：圓頂、外框、背板的鋁色，網罩（ShaderGraph：孔洞＋孔後的織網）、
// 孔後襯裡、腳圈等全部一起換。以前銀／粉／灰是拿星光色的材質自己染 baseColor，網罩換成純色 PBR、
// 孔後塗黑——跟官圖比，外框偏暗、網孔是死黑、看不到織網。
//
// RealityKit 沒有選變體的 API，但載入 .usda 時會照 USD 的組合規則解析：寫一個只有一行 reference、
// 帶 variants = { Color = "Silver" } 的小 .usda，載進來的就是那個變體。這裡把它寫到 Caches，
// 載入後只取「節點名 → 材質」，套到畫面上那一份模型上（幾何、層級、拆解位移都不動）。
import AppKit
import Foundation
import RealityKit

enum DeviceFinish {
    /// Finish → USDZ 變體名（G4 白不是 Apple 的變體）
    static func variant(_ f: Finish) -> String? {
        switch f {
        case .silver: return "Silver"
        case .starlight: return "Starlight"
        case .rose: return "Rose_Pink"
        case .gray: return "Space_Gray"
        case .g4: return nil
        }
    }

    /// 節點名（同名時加上出現序號）→ 那個節點的材質
    typealias MaterialMap = [String: [any Material]]

    private static var cache: [String: MaterialMap] = [:]

    /// 走過整棵樹收集材質；display 是螢幕面，不收（它的材質是我們的貼圖）
    static func snapshot(_ root: Entity, skip: Set<String> = ["RFkcSjAtJLGqwDA"]) -> MaterialMap {
        var map: MaterialMap = [:]
        var seen: [String: Int] = [:]
        func walk(_ e: Entity) {
            if let m = e as? ModelEntity, let mats = m.model?.materials, !skip.contains(m.name), !m.name.hasPrefix("anatomy.") {
                let n = seen[m.name, default: 0]; seen[m.name] = n + 1
                map[n == 0 ? m.name : "\(m.name)#\(n)"] = mats
            }
            for c in e.children { walk(c) }
        }
        walk(root)
        return map
    }

    /// 把 map 裡有的節點換成那份材質；回傳換了幾件。同名節點照走訪順序對上。
    @discardableResult
    static func apply(_ map: MaterialMap, to root: Entity, skip: Set<String> = ["RFkcSjAtJLGqwDA"]) -> Int {
        var seen: [String: Int] = [:]
        var count = 0
        func walk(_ e: Entity) {
            if let m = e as? ModelEntity, m.model != nil, !skip.contains(m.name), !m.name.hasPrefix("anatomy.") {
                let n = seen[m.name, default: 0]; seen[m.name] = n + 1
                if let mats = map[n == 0 ? m.name : "\(m.name)#\(n)"] { m.model?.materials = mats; count += 1 }
            }
            for c in e.children { walk(c) }
        }
        walk(root)
        return count
    }

    /// 某個變體的材質（第一次用才載，之後快取）；載不到回 nil，呼叫端退回舊的染色做法
    static func materials(for f: Finish) -> MaterialMap? {
        guard let v = variant(f) else { return nil }
        if let m = cache[v] { return m }
        guard let usdz = Bundle.module.url(forResource: "apple-homeview", withExtension: "usdz") else { return nil }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomePlay/finish", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("homeview-\(v).usda")
        guard (try? wrapper(variant: v, usdz: usdz).write(to: url, atomically: true, encoding: .utf8)) != nil,
              let root = try? Entity.load(contentsOf: url) else {
            log("USDZ 變體載入失敗：\(v)")
            return nil
        }
        let map = snapshot(root)
        cache[v] = map
        log("USDZ Color 變體 \(v)：\(map.count) 件材質")
        return map
    }

    /// 只有一個 reference 加變體選擇的 .usda（defaultPrim 跟原檔一樣，節點名才對得上）
    static func wrapper(variant v: String, usdz: URL) -> String {
        let path = usdz.path.replacingOccurrences(of: "@", with: "%40")
        return """
        #usda 1.0
        (
            defaultPrim = "BWlDYVsDFBbBvgZ"
            metersPerUnit = 0.01
            upAxis = "Y"
        )

        over "BWlDYVsDFBbBvgZ" (
            prepend references = @\(path)@
            variants = {
                string Color = "\(v)"
            }
        )
        {
        }

        """
    }

    /// 孔後織網的「腔體遮蔽」：Apple 的官圖是路徑追蹤，孔裡的織網被孔壁遮掉大半光；RealityKit 沒有這種遮蔽，
    /// 照原材質會亮成一片灰（官圖孔內 10% 分位亮度 31，我們 64–95；0.35 時 ≈ 32）。只壓暗孔後那幾層的 baseColor。
    /// 1＝不壓；--cavity 可改（校準用）。
    static let cavity: Float = {
        if let i = CommandLine.arguments.firstIndex(of: "--cavity"), i + 1 < CommandLine.arguments.count,
           let v = Float(CommandLine.arguments[i + 1]), v >= 0, v <= 1 { return v }
        return 0.35
    }()
    static func darkenCavity(_ parts: [ModelEntity], k: Float = cavity) {
        guard k < 1 else { return }
        for e in parts {
            guard var mats = e.model?.materials else { continue }
            for i in mats.indices {
                guard var p = mats[i] as? PhysicallyBasedMaterial,
                      let c = p.baseColor.tint.usingColorSpace(.sRGB) else { continue }
                let f = CGFloat(k)
                p.baseColor.tint = NSColor(srgbRed: c.redComponent * f, green: c.greenComponent * f,
                                           blue: c.blueComponent * f, alpha: c.alphaComponent)
                mats[i] = p
            }
            e.model?.materials = mats
        }
    }

    static func selftest(_ check: (Bool, String) -> Void) {
        check(Finish.allCases.compactMap(variant).count == 4 && variant(.g4) == nil, "finish：四色對上 USDZ 變體")
        let w = wrapper(variant: "Silver", usdz: URL(fileURLWithPath: "/a/b.usdz"))
        check(w.contains("@/a/b.usdz@") && w.contains("string Color = \"Silver\""), "finish：變體包裝 .usda")
    }
}
