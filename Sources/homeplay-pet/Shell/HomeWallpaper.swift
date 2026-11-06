// 體驗追趕 P4-3：主畫面桌布的第二種來源——從照片牆（照片錶面讀的那個資料夾，預設「圖片 › HomePlay」）挑一張。
//
// 預設照舊是「剛才那個錶面」模糊壓暗（2.0 R3）；選了照片就改用照片，經同一條材質管線（Shell.captureHomeBackdrop：
// 等比填滿成正方形 → 模糊 σ18 → 壓暗、平均亮度鉗在 0.45），圖示玻璃、面板、Dock 都照舊疊在上面。
// Look 聯動：照片的平均色找最近的 Look 底色當建議（設定頁一顆「套用」，不自動換）。
// 快照：--home-wallpaper <檔案路徑>。

import AppKit
import ImageIO

enum HomeWallpaper {
    static let defaultsKey = "shell.homeWallpaperPhoto"

    /// 選的照片（檔案路徑）；nil＝跟著錶面
    nonisolated(unsafe) static var photoPath: String? = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--home-wallpaper"), i + 1 < a.count { return a[i + 1] }
        return UserDefaults.standard.string(forKey: defaultsKey)
    }()

    static func set(_ path: String?) {
        photoPath = path
        if let path { UserDefaults.standard.set(path, forKey: defaultsKey) } else { UserDefaults.standard.removeObject(forKey: defaultsKey) }
        Shell.captureHomeBackdrop(Shell.lastFaceShot)   // 換了來源：馬上重算桌布（跟著錶面就用最後一次的錶面畫面）
        SB.pageCache.removeAll()
    }

    /// 照片牆：資料夾裡的照片（照檔名排）
    static func photos(in folder: URL = PhotoShelf.defaultFolder) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { PhotoShelf.exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    nonisolated(unsafe) private static var cache: (path: String, image: CGImage?)?
    /// 讀一張（縮到長邊 maxPixel、照 EXIF 轉正）；讀不到也記住，不每幀重讀
    static func load(_ path: String, maxPixel: Int = 1400) -> CGImage? {
        if let c = cache, c.path == path { return c.image }
        var img: CGImage?
        if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) {
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                         kCGImageSourceCreateThumbnailWithTransform: true]
            img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }
        cache = (path, img)
        return img
    }

    /// 等比填滿：把 size 的圖放進 into，置中裁切（純函式）
    static func aspectFill(_ size: CGSize, into box: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: box) }
        let k = max(box.width / size.width, box.height / size.height)
        let w = size.width * k, h = size.height * k
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    /// 桌布的原圖：選了照片＝照片填滿成跟錶面畫面一樣大的正方形；否則＝錶面畫面
    static func source(faceShot: CGImage?) -> CGImage? {
        guard let p = photoPath, let photo = load(p) else { return faceShot }
        let side = faceShot.map { max($0.width, $0.height) } ?? 1024
        let r = aspectFill(CGSize(width: photo.width, height: photo.height), into: CGSize(width: side, height: side))
        return makeImage(side, side) { g in g.interpolationQuality = .high; g.draw(photo, in: r) }
    }

    /// 建議的 Look：照片平均色離哪一個 Look 的底色最近（sRGB 距離；純函式）
    static func suggestedLook(for c: NSColor) -> HVTruth.Look {
        guard let s = c.usingColorSpace(.sRGB) else { return HVTruth.looks[0] }
        func d(_ l: HVTruth.Look) -> CGFloat {
            guard let b = l.background_color.usingColorSpace(.sRGB) else { return .greatestFiniteMagnitude }
            return pow(s.redComponent - b.redComponent, 2) + pow(s.greenComponent - b.greenComponent, 2) + pow(s.blueComponent - b.blueComponent, 2)
        }
        return HVTruth.looks.min { d($0) < d($1) } ?? HVTruth.looks[0]
    }
    static var suggestedLook: HVTruth.Look? {
        guard let p = photoPath, let img = load(p), let avg = Shell.averageColor(img) else { return nil }
        return suggestedLook(for: avg)
    }
}

enum HomeWallpaperSelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        let wide = HomeWallpaper.aspectFill(CGSize(width: 400, height: 200), into: CGSize(width: 100, height: 100))
        let tall = HomeWallpaper.aspectFill(CGSize(width: 100, height: 300), into: CGSize(width: 100, height: 100))
        check(wide == CGRect(x: -50, y: 0, width: 200, height: 100) && tall == CGRect(x: 0, y: -100, width: 100, height: 300),
              "主畫面桌布：照片等比填滿、置中裁切")   // l10n-ignore
        check(HomeWallpaper.suggestedLook(for: srgb(0x93ACB2)).name == "Slate" && HomeWallpaper.suggestedLook(for: srgb(0xEAEAEA)).background == 0xEBEBEB,
              "主畫面桌布：照片色找最近的 Look 底色")   // l10n-ignore
        let saved = HomeWallpaper.photoPath
        HomeWallpaper.photoPath = nil
        let shot = makeImage(8, 8) { _ in }
        check(HomeWallpaper.source(faceShot: shot) === shot, "主畫面桌布：沒選照片＝跟著錶面")   // l10n-ignore
        HomeWallpaper.photoPath = saved
    }
}
