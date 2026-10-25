// 天氣 App 動態天空的「場景」：從天氣資料（WMO 代碼、日夜、日出日落）決定畫什麼，再把場景翻成一份外觀（漸層、雲、雨雪、星月、閃電、霧、風）。
// 這一層是純邏輯（selftest 測得到），兩個畫家都吃它：系統 VFX（WeatherSkyVFX）與我們自己的 Metal 天空（WeatherSkyMetal）。
// 數字的出處：docs/plans/weather-sky.md（對系統天氣 App 的截圖量出來的漸層、密度、速度）；量不到的照 iOS 天氣推斷，那裡有標。

import AppKit

enum SkyKind: String, CaseIterable {
    case clear, partlyCloudy, cloudy, fog, haze, drizzle, rain, heavyRain, thunder, snow, sleet, hail, windy

    /// Open-Meteo 的 WMO 代碼 → 場景（風大另外判斷：≥ 40 km/h 且不是降水）
    static func of(code: Int, wind: Double = 0) -> SkyKind {
        let k: SkyKind
        switch code {
        case 0: k = .clear
        case 1, 2: k = .partlyCloudy
        case 3: k = .cloudy
        case 45, 48: k = .fog
        case 51, 53, 55, 56, 57: k = .drizzle
        case 61, 63, 80, 81: k = .rain
        case 65, 82: k = .heavyRain
        case 66, 67: k = .sleet
        case 71, 73, 75, 77, 85, 86: k = .snow
        case 95: k = .thunder
        case 96, 99: k = .hail
        default: k = .cloudy
        }
        if wind >= 40, [.clear, .partlyCloudy, .cloudy].contains(k) { return .windy }
        return k
    }
}

/// 時段：dawn＝日出前 40 分鐘、sunrise＝日出後 40 分鐘、sunset＝日落前 40 分鐘、dusk＝日落後 40 分鐘
enum SkyTime: String, CaseIterable { case day, dawn, sunrise, sunset, dusk, night }

struct WeatherSkyScene: Equatable {
    var kind: SkyKind
    var time: SkyTime
    var moonPhase: Int = 14          // 0…27（系統的 moonPhase0…27.png）；14＝滿月

    /// 日出、日落前後 40 分鐘各分兩段（系統天氣 App 在這段有紫粉的地平線；日出前暗、日出後亮）
    static func time(minutes m: Int, sunrise: Int, sunset: Int) -> SkyTime {
        if m >= sunrise - 40 && m < sunrise { return .dawn }
        if m >= sunrise && m <= sunrise + 40 { return .sunrise }
        if m >= sunset - 40 && m < sunset { return .sunset }
        if m >= sunset && m <= sunset + 40 { return .dusk }
        return (m > sunrise && m < sunset) ? .day : .night
    }

    /// 月相：以 2000-01-06 18:14 UTC 的新月為基準，朔望月 29.53 天
    static func moonPhase(_ date: Date) -> Int {
        let ref = Date(timeIntervalSince1970: 947_182_440)
        let days = date.timeIntervalSince(ref) / 86_400
        let f = (days / 29.530588).truncatingRemainder(dividingBy: 1)
        return Int(((f < 0 ? f + 1 : f) * 28).rounded(.down)) % 28
    }

    /// 示範／快照：--demo-weather rain｜snow｜thunder｜clear-night｜cloudy｜fog…（不帶值＝舊的示範資料）
    static var demo: WeatherSkyScene? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--demo-weather"), i + 1 < a.count, !a[i + 1].hasPrefix("--") else { return nil }
        return parse(a[i + 1])
    }
    static func parse(_ s: String) -> WeatherSkyScene? {
        var name = s.lowercased(), time = SkyTime.day
        for t in SkyTime.allCases where name.hasSuffix("-" + t.rawValue) { time = t; name = String(name.dropLast(t.rawValue.count + 1)) }
        let alias: [String: SkyKind] = ["partly": .partlyCloudy, "partly-cloudy": .partlyCloudy, "heavy-rain": .heavyRain, "storm": .thunder]
        guard let k = alias[name] ?? SkyKind.allCases.first(where: { $0.rawValue.lowercased() == name }) else { return nil }
        return WeatherSkyScene(kind: k, time: time)
    }
    /// 示範場景對應的 WMO 代碼（讓文字、圖示跟天空一致）
    var demoCode: Int {
        switch kind {
        case .clear: return 0
        case .partlyCloudy: return 2
        case .cloudy, .windy: return 3
        case .fog, .haze: return 45
        case .drizzle: return 53
        case .rain: return 63
        case .heavyRain: return 65
        case .thunder: return 95
        case .snow: return 73
        case .sleet: return 67
        case .hail: return 96
        }
    }
}

// MARK: 外觀（兩個畫家共用的描述）

/// sRGB 0…1
struct SkyRGB: Equatable {
    var r, g, b: Float
    init(_ hex: UInt32) { r = Float(hex >> 16 & 0xff) / 255; g = Float(hex >> 8 & 0xff) / 255; b = Float(hex & 0xff) / 255 }
    init(r: Float, g: Float, b: Float) { self.r = r; self.g = g; self.b = b }
    func mix(_ o: SkyRGB, _ t: Float) -> SkyRGB { SkyRGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t) }
    var linear: SIMD3<Float> {
        func l(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4) }
        return SIMD3(l(r), l(g), l(b))
    }
    var luma: Float { 0.2126 * r + 0.7152 * g + 0.0722 * b }
}

/// 一層雲：用系統的哪一族雲圖、幾朵、多大、多亮、多快
struct CloudLayer: Equatable {
    var family: String        // "Cumulus_SingleL" 之類（系統 WeatherUI/VFX 裡的檔名前綴）
    var variants: Int         // 那一族有幾張（000…）
    var count: Int
    var width: Float          // 佔畫面寬的比例
    var yBand: ClosedRange<Float>   // 雲心的垂直位置（0 頂、1 底）
    var opacity: Float
    var speed: Float          // 每秒水平移動（畫面寬的比例）
    var light: SkyRGB         // 受光面顏色（太陽／月亮）
    var shade: SkyRGB         // 背光面顏色（天空的環境光）
    var tiled = false         // 雲毯：等距鋪滿整個寬度（不會露出空隙）
}

struct SkyLook: Equatable {
    var top: SkyRGB, middle: SkyRGB, bottom: SkyRGB
    var middleAt: Float = 0.55
    /// 太陽或月亮的位置（0…1，左上原點）與光暈
    var lightPos: SIMD2<Float> = [0.72, 0.12]
    var glow: SkyRGB = SkyRGB(0xffffff)
    var glowStrength: Float = 0
    var glowRadius: Float = 0.5
    var sunDisc: Float = 0              // 太陽本體亮度（晴天才有）
    var stars: Float = 0                // 星星不透明度
    var moon: Float = 0                 // 月亮不透明度
    var moonPhase: Int = 14
    var clouds: [CloudLayer] = []
    var rainBG = 0, rainFG = 0          // 雨滴數（遠、近）
    var rainSpeed: Float = 1.6          // 每秒落下幾個畫面高
    var rainOpacity: Float = 0.5
    var snowBG = 0, snowFG = 0
    var hail = 0
    var sleet = 0
    var fog: Float = 0                  // 霧（噪聲片）不透明度
    var fogTint: SkyRGB = SkyRGB(0xc9ced6)
    var wind: Float = 0                 // 風的流線不透明度
    var lightning = false
    var fallAngle: Float = 0.10         // 雨的斜度（tan）
}

extension WeatherSkyScene {
    /// 場景 → 外觀。漸層三色是從系統天氣 App 截圖量的（見 docs/plans/weather-sky.md 表一）。
    var look: SkyLook {
        // 1) 基底天色：晴朗的四個時段
        let clearSky: (SkyRGB, SkyRGB, SkyRGB) = {
            switch time {
            case .day: return (SkyRGB(0x2c61b3), SkyRGB(0x4f83c9), SkyRGB(0x8fb4dd))         // 推斷：日出後實測那組再飽和、地平線不帶粉
            case .dawn: return (SkyRGB(0x1c2842), SkyRGB(0x313b5e), SkyRGB(0x705e7d))        // 實測：廣州 06:04（日出 06:28 前 24 分）
            case .sunrise: return (SkyRGB(0x354e82), SkyRGB(0x6f7ca5), SkyRGB(0xb9a8b5))     // 實測：廣州 06:56（日出後 28 分）
            case .sunset: return (SkyRGB(0x3a5288), SkyRGB(0x8a7fa6), SkyRGB(0xe0a58c))      // 推斷：日出後那組、地平線偏暖
            case .dusk: return (SkyRGB(0x1a2442), SkyRGB(0x3a3a62), SkyRGB(0x8a6278))        // 推斷：日出前那組、地平線偏紅
            case .night: return (SkyRGB(0x070c1c), SkyRGB(0x111a33), SkyRGB(0x253150))       // 推斷：比日出前再暗一階
            }
        }()
        var l = SkyLook(top: clearSky.0, middle: clearSky.1, bottom: clearSky.2)
        let night = time == .night, day = time == .day
        let twilight = time == .dawn || time == .dusk          // 太陽在地平線下
        let dim: Float = night ? 0.35 : (day ? 1 : (twilight ? 0.5 : 0.75))
        l.moonPhase = moonPhase
        // 光源：白天太陽在右上；夜裡月亮在右上；日出日落壓低到地平線附近
        switch time {
        case .day: l.lightPos = [0.93, -0.03];   // 太陽大半在右上角外，只露光暈（右上住著時間）
             l.glow = SkyRGB(0xfff3d6); l.glowStrength = 0.22; l.glowRadius = 0.3; l.sunDisc = 1
        case .sunrise, .sunset: l.lightPos = [0.70, 0.98]; l.glow = SkyRGB(0xffc4a0); l.glowStrength = 0.18; l.glowRadius = 0.6
        case .dawn, .dusk: l.lightPos = [0.70, 1.05]; l.glow = SkyRGB(0xd89aa8); l.glowStrength = 0.10; l.glowRadius = 0.55
        case .night: l.lightPos = [0.17, 0.27];   // 月亮在左上、返回鈕底下（右上住著時間）
             l.glow = SkyRGB(0xb9c8ff); l.glowStrength = 0.10; l.glowRadius = 0.35
        }
        if night || twilight { l.stars = night ? 0.9 : 0.5 }   // 實測：日出前 24 分還看得到星星，日出後就沒了
        if night { l.moon = 1 }

        // 雲的光：白天白、日出日落暖、夜裡月光藍灰
        let litDay = SkyRGB(0xffffff), litWarm = SkyRGB(0xffd2b0), litNight = SkyRGB(0x8a94b2)
        let lit = day ? litDay : (night ? litNight : (twilight ? litNight.mix(litWarm, 0.5) : litWarm))
        func shade(_ base: SkyRGB) -> SkyRGB { base.mix(SkyRGB(0x000000), 0.15) }

        // 2) 各種天氣在基底上加東西（灰天的三色：實測北京「多雲」、上海「毛毛雨」06:04 的卡片；白天版本推斷）
        func overcast(_ dayRGB: (UInt32, UInt32, UInt32), _ dawnRGB: (UInt32, UInt32, UInt32), _ nightRGB: (UInt32, UInt32, UInt32)) {
            // 日出後／日落前：白天與日出前那組的中間（實測北京「多雲」06:56 卡片 ≈ 這個值）
            let mid = (SkyRGB(dayRGB.0).mix(SkyRGB(dawnRGB.0), 0.5), SkyRGB(dayRGB.1).mix(SkyRGB(dawnRGB.1), 0.5), SkyRGB(dayRGB.2).mix(SkyRGB(dawnRGB.2), 0.5))
            if time == .sunrise || time == .sunset { l.top = mid.0; l.middle = mid.1; l.bottom = mid.2; l.stars = 0; l.moon = 0; l.sunDisc = 0; l.glowStrength *= 0.1; return }
            let c = day ? dayRGB : (night ? nightRGB : dawnRGB)
            l.top = SkyRGB(c.0); l.middle = SkyRGB(c.1); l.bottom = SkyRGB(c.2)
            l.stars = 0; l.moon = 0; l.sunDisc = 0; l.glowStrength *= 0.1
        }
        // 陰天的雲是中性灰（實測北京、上海卡片：雲的亮部 ≈ 天色 +35、不偏暖）
        let grey = day ? SkyRGB(0xe9ecf1) : (night ? SkyRGB(0x4c505b) : (twilight ? SkyRGB(0x7c808a) : SkyRGB(0xb4b8c2)))
        func blanket(_ family: String, _ variants: Int, y: ClosedRange<Float>, count: Int = 3, width: Float = 2.0, opacity: Float, light: Float) -> CloudLayer {
            CloudLayer(family: family, variants: variants, count: count, width: width, yBand: y, opacity: opacity, speed: 0.004,
                       light: grey.mix(l.middle, 1 - light), shade: l.top.mix(SkyRGB(0x000000), 0.2), tiled: true)
        }
        func puffs(_ family: String, _ variants: Int, n: Int, width: Float, y: ClosedRange<Float>, opacity: Float, light: Float, speed: Float = 0.007) -> CloudLayer {
            CloudLayer(family: family, variants: variants, count: n, width: width, yBand: y, opacity: opacity, speed: speed,
                       light: grey.mix(l.middle, 1 - light), shade: l.top.mix(SkyRGB(0x000000), 0.3))
        }
        switch kind {
        case .clear:
            break
        case .partlyCloudy:
            l.clouds = [CloudLayer(family: "Cumulus_SingleM", variants: 15, count: 3, width: 0.55, yBand: 0.12...0.5, opacity: 0.7 * dim + 0.25, speed: 0.004, light: lit, shade: shade(l.middle)),
                        CloudLayer(family: "Cumulus_SingleL", variants: 10, count: 3, width: 0.85, yBand: 0.2...0.7, opacity: 0.85 * dim + 0.15, speed: 0.007, light: lit, shade: shade(l.middle))]
            l.stars *= 0.6
        case .cloudy, .windy:
            overcast((0x6d7c92, 0x8796ab, 0xa9b5c4), (0x323640, 0x4a4e5a, 0x575b67), (0x16181f, 0x23262f, 0x30333d))
            // 實測北京卡片：暗底上有大塊、亮 +40 左右的雲團——雲毯打底，大朵積雲拉開明暗
            l.clouds = [blanket("Stratus_Blanket", 8, y: 0.15...0.55, opacity: 0.9, light: 0.45),
                        blanket("Altostratus_Blanket", 8, y: 0.35...0.8, opacity: 0.6, light: 0.6),
                        puffs("Cumulus_SingleL", 10, n: 5, width: 1.35, y: 0.1...0.8, opacity: 0.9, light: 0.9)]
            if kind == .windy { l.wind = 0.55; l.clouds = l.clouds.map { var c = $0; c.speed *= 5; return c } }
        case .fog, .haze:
            if kind == .fog { overcast((0x8f9aa8, 0xa6aeb9, 0xbfc5cc), (0x4b4f5b, 0x5d616c, 0x70737d), (0x1e2129, 0x2b2e36, 0x3a3d45)) }
            else { l.top = l.top.mix(SkyRGB(0xb8a88c), 0.35); l.middle = l.middle.mix(SkyRGB(0xcbb995), 0.45); l.bottom = l.bottom.mix(SkyRGB(0xd8c7a0), 0.55); l.stars *= 0.3 }
            l.fog = kind == .fog ? 0.75 : 0.45
            l.fogTint = kind == .fog ? l.bottom.mix(SkyRGB(0xffffff), 0.25) : SkyRGB(0xd9c9a6)
        case .drizzle, .rain, .heavyRain, .thunder, .sleet, .hail:
            let storm = kind == .thunder || kind == .hail
            if storm {
                overcast((0x3e4656, 0x4f5767, 0x5f6676), (0x22252e, 0x2f323c, 0x3b3e49), (0x0d0e13, 0x17191f, 0x22242c))
            } else {
                overcast((0x6a7890, 0x7c8aa0, 0x93a0b3), (0x56606f, 0x63707f, 0x697488), (0x1b1f27, 0x262b35, 0x313744))
            }
            l.clouds = [blanket(storm ? "Cumulonimbus_BlanketL" : "Stratus_Blanket", storm ? 4 : 8, y: 0.12...0.5, opacity: 0.95, light: storm ? 0.4 : 0.5),
                        blanket("Altostratus_Blanket", 8, y: 0.4...0.85, opacity: 0.7, light: 0.55),
                        puffs("Nimbostratus_SingleL", 10, n: 5, width: 1.4, y: 0.05...0.8, opacity: 0.85, light: storm ? 0.55 : 0.8, speed: 0.01)]
            switch kind {
            case .drizzle: l.rainBG = 260; l.rainFG = 0; l.rainOpacity = 0.35; l.rainSpeed = 1.1
            case .rain: l.rainBG = 700; l.rainFG = 90; l.rainOpacity = 0.45
            case .heavyRain: l.rainBG = 1400; l.rainFG = 220; l.rainOpacity = 0.55; l.rainSpeed = 2.0; l.fallAngle = 0.16
            case .thunder: l.rainBG = 900; l.rainFG = 140; l.rainOpacity = 0.5; l.lightning = true
            case .sleet: l.rainBG = 350; l.sleet = 260; l.rainOpacity = 0.35
            case .hail: l.rainBG = 500; l.hail = 160; l.rainOpacity = 0.4; l.lightning = true
            default: break
            }
        case .snow:
            overcast((0x8290a6, 0x99a5b8, 0xb7c0cd), (0x4a5060, 0x5c6272, 0x6d7383), (0x1f232c, 0x2c303a, 0x3b3f4a))
            l.clouds = [blanket("Stratus_Blanket", 8, y: 0.1...0.45, opacity: 0.85, light: 0.6),
                        blanket("Altostratus_Blanket", 8, y: 0.35...0.8, opacity: 0.55, light: 0.7)]
            l.snowBG = 520; l.snowFG = 120
        }
        return l
    }
}
