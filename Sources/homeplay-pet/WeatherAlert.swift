import Foundation

// 「快要下雨了」：照 iOS 天氣的「下一小時降雨」通知——未來 60 分鐘內會開始降雨／雪／雷雨才提醒；
// 現在已經在下就不提醒（iOS 也只提醒「開始」）；資料超過 2 小時沒更新不提醒（會誤報）。
// 純邏輯，沒有網路與時鐘：資料與現在時間都從參數進來，selftest 直接餵。

/// 一個預報時段（15 分鐘或 1 小時）：Open-Meteo 的 minutely_15 或 hourly 轉成同一種形狀
struct WeatherRainSlot: Equatable, Codable {
    var start: Double         // 時段開始（epoch 秒）
    var span: Double          // 時段長度（秒）：900＝15 分鐘資料、3600＝逐時
    var code: Int             // WMO 天氣代碼
    var prob: Double? = nil   // 降水機率 %（只有逐時有）
    var mm: Double? = nil     // 降水量 mm（只有 15 分鐘有）
}

enum WeatherAlert {
    enum Kind: String { case rain, snow, thunder }

    static let lookahead: TimeInterval = 3600      // 往後看 60 分鐘
    static let maxAge: TimeInterval = 2 * 3600     // 資料超過 2 小時沒更新就不提醒
    static let probThreshold = 60.0                // 逐時資料：降水機率 ≥ 60% 算會下

    /// WMO 天氣代碼 → 降水種類（nil＝沒在下）。51–67 毛毛雨／雨／凍雨、80–82 陣雨；71–77 雪、85–86 陣雪；95–99 雷雨
    static func kind(code: Int) -> Kind? {
        switch code {
        case 51...67, 80...82: return .rain
        case 71...77, 85...86: return .snow
        case 95...99: return .thunder
        default: return nil
        }
    }

    /// 這個時段算不算「在下」：代碼屬於降水、15 分鐘降水量 ≥ 0.1 mm、或逐時機率 ≥ 60%（代碼不是降水時當雨）
    private static func kind(of s: WeatherRainSlot) -> Kind? {
        if let k = kind(code: s.code) { return k }
        if let mm = s.mm, mm >= 0.1 { return .rain }
        if let p = s.prob, p >= probThreshold { return .rain }
        return nil
    }

    /// 接下來 60 分鐘內第一個開始降水的時段：(種類, 開始時間)。沒有、現在就在下、資料太舊都回 nil
    static func next(data: WeatherData, updatedAt: Date?, now: Date) -> (kind: Kind, start: Date)? {
        guard let updatedAt, now.timeIntervalSince(updatedAt) <= maxAge, now >= updatedAt.addingTimeInterval(-300) else { return nil }
        if kind(code: data.code) != nil { return nil }   // 現在已經在下
        let t = now.timeIntervalSince1970
        let slots = (data.rainSlots ?? []).sorted { $0.start < $1.start }
        // 現在所在的那一格也在下：已經在下（15 分鐘資料才這樣判，逐時的機率只代表整點那一格）
        if let cur = slots.first(where: { $0.start <= t && t < $0.start + $0.span }), cur.span <= 900, kind(of: cur) != nil { return nil }
        for s in slots where s.start > t && s.start <= t + lookahead {
            if let k = kind(of: s) { return (k, Date(timeIntervalSince1970: s.start)) }
        }
        return nil
    }

    // MARK: 收起（本地：這一次降雨不再出現）

    /// 使用者按了「收起」的那一次降雨的開始時間；之後 60 分鐘內開始的都當同一場
    nonisolated(unsafe) static var dismissedStart: Double?
    static func dismiss(start: Date) { dismissedStart = start.timeIntervalSince1970 }
    static func isDismissed(start: Date) -> Bool {
        guard let d = dismissedStart else { return false }
        return abs(start.timeIntervalSince1970 - d) <= lookahead
    }
}
