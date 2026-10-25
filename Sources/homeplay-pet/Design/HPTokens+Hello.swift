// 2.0 hello：開機 hello 的顏色（量自參考影片，量法與數值見 docs/plans/hello.md §1.3）。
// 這些是一段動畫的美術，不是介面語意色；放在 HPDS 讓別處（官網素材、iPhone 版）拿同一組。

import AppKit

extension HPTokens {
    enum Hello {
        /// 行（上→下）× 列（左→右），sRGB 0…255
        static let grid: [[(CGFloat, CGFloat, CGFloat)]] = [
            [(0xE8, 0xB8, 0x55), (0xF0, 0xB0, 0x2B), (0xDA, 0xD6, 0x9B), (0xD8, 0xDC, 0xA7)],
            [(0xE2, 0xBC, 0x75), (0xF1, 0xAA, 0x23), (0xEA, 0xCE, 0x53), (0xE4, 0xD4, 0x5F)],
            [(0xDE, 0xBE, 0x85), (0xEF, 0x9C, 0x0F), (0xF1, 0xA8, 0x1D), (0xE6, 0xBE, 0x55)],
            [(0xD8, 0xC6, 0xA1), (0xF0, 0x9E, 0x37), (0xEC, 0xA8, 0x45), (0xDC, 0xC0, 0x8F)],
        ]
        /// 紅色色塊的核心
        static let red: (CGFloat, CGFloat, CGFloat) = (0xE2, 0x12, 0x1F)
        /// 螢幕中心偏上那團淡黃（hello 底下）：量的中心色 #F0DC52
        static let glow: (x: CGFloat, y: CGFloat, r: CGFloat, c: (CGFloat, CGFloat, CGFloat)) = (0.55, 0.42, 0.42, (0xF2, 0xDC, 0x54))
        /// 筆畫用加亮混合加上去的量：紅底上 +28/+64/+59、黃底上 +17/+55/+50（所以在紅色上看起來是粉紅）
        static let ink = NSColor(srgbRed: 0.25, green: 0.25, blue: 0.22, alpha: 1)
        static let inkGlow = NSColor(srgbRed: 1, green: 0.95, blue: 0.6, alpha: 0.18)
        /// 亮起之前（只有產品影片會看到）
        static let screenOff = NSColor(white: 0.02, alpha: 1)
        /// 暗的房間：整層壓到 45%
        static let nightDim = NSColor(white: 0, alpha: 0.55)
    }
}
