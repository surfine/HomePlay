// 天氣 App 動態天空的自檢：天氣代碼 → 場景、日出日落時段、月相、示範旗標解析、外觀的基本不變量，
// 以及「系統渲染器不在 → 安靜地改用我們的 Metal 天空」與「強制退路」兩條路真的畫得出不是整片同色的天空。

import AppKit
import Metal

enum WeatherSkySelfTest {
    static func run(_ check: (Bool, String) -> Void) {
        // 代碼 → 場景
        let map: [(Int, SkyKind)] = [(0, .clear), (1, .partlyCloudy), (2, .partlyCloudy), (3, .cloudy), (45, .fog), (53, .drizzle), (63, .rain),
                                     (65, .heavyRain), (67, .sleet), (73, .snow), (95, .thunder), (99, .hail)]
        check(map.allSatisfy { SkyKind.of(code: $0.0) == $0.1 }, "天氣天空：WMO 代碼 → 場景") // l10n-ignore：自檢訊息
        check(SkyKind.of(code: 0, wind: 50) == .windy && SkyKind.of(code: 63, wind: 50) == .rain, "天氣天空：大風只蓋過晴／多雲／陰") // l10n-ignore：自檢訊息
        // 時段：日出 06:00、日落 18:00
        check(WeatherSkyScene.time(minutes: 5 * 60 + 30, sunrise: 360, sunset: 1080) == .dawn
              && WeatherSkyScene.time(minutes: 6 * 60 + 20, sunrise: 360, sunset: 1080) == .sunrise
              && WeatherSkyScene.time(minutes: 12 * 60, sunrise: 360, sunset: 1080) == .day
              && WeatherSkyScene.time(minutes: 17 * 60 + 40, sunrise: 360, sunset: 1080) == .sunset
              && WeatherSkyScene.time(minutes: 18 * 60 + 30, sunrise: 360, sunset: 1080) == .dusk
              && WeatherSkyScene.time(minutes: 23 * 60, sunrise: 360, sunset: 1080) == .night, "天氣天空：日出前後／白天／日落前後／夜晚") // l10n-ignore：自檢訊息
        // 月相：2024-01-11 11:57 UTC 是新月、2024-01-25 17:54 UTC 是滿月
        let newMoon = WeatherSkyScene.moonPhase(Date(timeIntervalSince1970: 1_704_974_220))
        let fullMoon = WeatherSkyScene.moonPhase(Date(timeIntervalSince1970: 1_706_205_240))
        check((newMoon <= 1 || newMoon >= 27) && (13...15).contains(fullMoon), "天氣天空：月相（新月≈0、滿月≈14）") // l10n-ignore：自檢訊息
        // 示範旗標
        check(WeatherSkyScene.parse("clear-night") == WeatherSkyScene(kind: .clear, time: .night)
              && WeatherSkyScene.parse("heavy-rain")?.kind == .heavyRain && WeatherSkyScene.parse("thunder")?.time == .day
              && WeatherSkyScene.parse("bogus") == nil, "天氣天空：--demo-weather 解析") // l10n-ignore：自檢訊息
        // 外觀不變量
        let clear = WeatherSkyScene(kind: .clear, time: .day).look, night = WeatherSkyScene(kind: .clear, time: .night).look
        let rain = WeatherSkyScene(kind: .rain, time: .day).look, storm = WeatherSkyScene(kind: .thunder, time: .night).look
        let cloudyNight = WeatherSkyScene(kind: .cloudy, time: .night).look
        check(clear.clouds.isEmpty && clear.rainBG == 0 && clear.sunDisc > 0, "天氣天空：晴天沒有雲雨、有太陽") // l10n-ignore：自檢訊息
        check(night.moon > 0 && night.stars > 0 && night.top.luma < clear.top.luma, "天氣天空：晴夜有月亮星星、比白天暗") // l10n-ignore：自檢訊息
        check(rain.rainBG > 0 && !rain.clouds.isEmpty && !rain.lightning && storm.lightning, "天氣天空：雨有雨滴與雲，雷雨才有閃電") // l10n-ignore：自檢訊息
        check(cloudyNight.stars == 0 && cloudyNight.moon == 0, "天氣天空：陰天看不到星星月亮") // l10n-ignore：自檢訊息
        // 整片同色判斷
        let solid = makeImage(64, 64) { c in c.setFillColor(NSColor.white.cgColor); c.fill(CGRect(x: 0, y: 0, width: 64, height: 64)) }
        let grad = makeImage(64, 64) { c in
            c.setFillColor(NSColor.blue.cgColor); c.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            c.setFillColor(NSColor.white.cgColor); c.fill(CGRect(x: 0, y: 32, width: 64, height: 32))
        }
        check(WeatherLiveSky.isUniform(solid) && !WeatherLiveSky.isUniform(grad), "天氣天空：整片同色的健檢") // l10n-ignore：自檢訊息
        // 退路一：系統渲染器「不在」→ 自動用我們的
        guard MTLCreateSystemDefaultDevice() != nil else { check(true, "天氣天空：沒有 Metal，略過畫圖檢查"); return } // l10n-ignore：自檢訊息
        WeatherSkyVFX.simulateMissing = true
        let a = WeatherLiveSky()
        a.configure(WeatherSkyScene(kind: .rain, time: .day))
        let ia = a.renderSync(frames: 3)
        WeatherSkyVFX.simulateMissing = false
        check(a.source == .ours && ia != nil && !WeatherLiveSky.isUniform(ia!) && a.fallbackReason.contains("unavailable"),
              "天氣天空：系統渲染器不在時自動改用自己的天空（\(a.source.rawValue)）") // l10n-ignore：自檢訊息
        // 退路二：強制退路（selftest 旗標）
        let b = WeatherLiveSky(forceFallback: true)
        b.configure(WeatherSkyScene(kind: .clear, time: .night))
        let ib = b.renderSync(frames: 2)
        check(b.source == .ours && ib != nil && !WeatherLiveSky.isUniform(ib!) && ib!.width == 1024, "天氣天空：強制退路畫得出 1024² 的夜空") // l10n-ignore：自檢訊息
    }
}
