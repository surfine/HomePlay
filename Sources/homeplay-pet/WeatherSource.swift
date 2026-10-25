import AppKit
import CoreLocation

// 天氣錶面的真資料：Open-Meteo（免金鑰）＋ CoreLocation（降低精確度，只在天氣錶面第一次出現時才問「使用 App 期間」）。
// 定位拿不到／被拒絕：用 UserDefaults 裡上一次的位置；都沒有就讓錶面顯示「—」，不崩、不擋。
// 每 30 分鐘刷新；網路在背景佇列，結果回主執行緒發布並叫錶面重畫。
// 快照／測試：環境變數 HOMEPLAY_WEATHER_JSON='{"temp":22,"hi":25,"lo":19,"code":2,"wind":11,"humidity":76,"aqi":21,"sunset":"17:21","city":"臺北市"}'
// 直接當資料用（不連網、不問定位）；可再加 "night":true／false。

/// 2.0：天氣 App 用的逐時與逐日預報（舊的快取沒有這兩欄＝nil）
struct WeatherHour: Equatable, Codable {
    var label: String         // 當地小時 "14"
    var temp: Double
    var code: Int
    var night: Bool
}
struct WeatherDay: Equatable, Codable {
    var date: String          // 當地 "yyyy-MM-dd"
    var hi: Double
    var lo: Double
    var code: Int
}

struct WeatherData: Equatable, Codable {
    var temp: Double
    var hi: Double
    var lo: Double
    var code: Int
    var wind: Double          // km/h
    var humidity: Double      // %
    var aqi: Double?
    var sunset: String?       // 當地 "HH:mm"
    var city: String?
    var night: Bool?          // nil＝由時間與日落推算
    var hourly: [WeatherHour]? = nil    // 2.0：接下來 12 小時
    var daily: [WeatherDay]? = nil      // 2.0：今天起 10 天（舊快取 5 天）
    var sunrise: String? = nil          // 2.0 天氣 App：當地 "HH:mm"（舊快取沒有）
}

final class WeatherSource: NSObject, CLLocationManagerDelegate {
    static let shared = WeatherSource()
    static let usageKey = "NSLocationUsageDescription"
    static let envKey = "HOMEPLAY_WEATHER_JSON"

    private(set) var data: WeatherData?
    private(set) var version = 0
    /// 2.0 P02：資料是什麼時候抓到的（小工具超過 2 小時沒更新就標「更新於 …」；HIG-WID-110）
    private(set) var updatedAt: Date?
    /// 2.0 depth：沒有資料時為什麼（錶面、天氣 App 寫原因，不是一排「—」）
    enum Status { case ok, noLocation, offline }
    private(set) var status = Status.ok
    /// 沒資料時給人看的一句話（有資料或還在等第一次就 nil）
    var statusText: String? {
        guard data == nil else { return nil }
        switch status {
        case .ok: return nil
        case .noLocation: return L("weather.status.noLocation", "允许定位后才会显示天气")
        case .offline: return L("weather.status.offline", "连不上天气服务，稍后会再试")
        }
    }
    /// 錶面左上那一格放得下的短句
    var statusShort: String? {
        guard data == nil else { return nil }
        switch status {
        case .ok: return nil
        case .noLocation: return L("weather.status.noLocation.short", "需要定位")
        case .offline: return L("weather.status.offline.short", "没有网络")
        }
    }
    private var retries = 0
    private var onChange: (() -> Void)?
    private var started = false
    private var timer: Timer?
    private var manager: CLLocationManager?
    private var lastFetch = Date.distantPast
    private var fetching = false
    private let queue = DispatchQueue(label: "homeplay.weather", qos: .utility)
    private let defaults = UserDefaults.standard

    /// 沒有用途說明就去要定位權限，系統會直接讓進程崩掉；所以只在打包成 App 後才問
    static var canAskLocation: Bool { Bundle.main.object(forInfoDictionaryKey: usageKey) != nil }

    /// 錶面每次畫都可以呼叫：第一次才真的啟動，之後只更新「資料變了叫誰重畫」
    func activate(_ onChange: @escaping () -> Void) {
        self.onChange = onChange
        guard !started else { return }
        started = true
        // 快照：HOMEPLAY_WEATHER_STATUS=offline｜noLocation：沒有資料、只有原因（驗收空狀態）
        if let s = ProcessInfo.processInfo.environment["HOMEPLAY_WEATHER_STATUS"] { status = s == "offline" ? .offline : .noLocation; return }
        if let json = ProcessInfo.processInfo.environment[Self.envKey], let d = Self.parse(json) {
            data = d; version += 1
            updatedAt = Self.parseAge(json).map { Date().addingTimeInterval(-$0 * 60) }   // 快照："ageMinutes":180＝三小時前的資料
            return
        }
        if let raw = defaults.data(forKey: "HomePlayWeatherLast"), let d = try? JSONDecoder().decode(WeatherData.self, from: raw) {
            data = d; version += 1
            updatedAt = defaults.object(forKey: "HomePlayWeatherLastAt") as? Date
        }
        DispatchQueue.main.async { [weak self] in self?.startOnMain() }
    }

    static func parseAge(_ json: String) -> Double? {
        guard let raw = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return nil }
        return (o["ageMinutes"] as? NSNumber)?.doubleValue
    }

    static func parse(_ json: String) -> WeatherData? {
        guard let raw = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return nil }
        func num(_ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        guard let t = num("temp") else { return nil }
        return WeatherData(temp: t, hi: num("hi") ?? t, lo: num("lo") ?? t, code: Int(num("code") ?? 0), wind: num("wind") ?? 0,
                           humidity: num("humidity") ?? 0, aqi: num("aqi"), sunset: o["sunset"] as? String, city: o["city"] as? String,
                           night: o["night"] as? Bool)
    }

    // MARK: 定位

    private func startOnMain() {
        let t = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common); timer = t
        guard Self.canAskLocation else { fetchWithCachedLocation(); return }
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyReduced
        manager = m
        switch m.authorizationStatus {
        case .notDetermined: m.requestWhenInUseAuthorization()
        case .denied, .restricted: fetchWithCachedLocation()
        default: m.requestLocation()
        }
    }

    private func refresh() {
        if let m = manager, m.authorizationStatus == .authorizedAlways || m.authorizationStatus == .authorized { m.requestLocation() }
        else { fetchWithCachedLocation() }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .notDetermined: break
        case .denied, .restricted: fetchWithCachedLocation()
        default: manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { fetchWithCachedLocation(); return }
        defaults.set(loc.coordinate.latitude, forKey: "HomePlayWeatherLat")
        defaults.set(loc.coordinate.longitude, forKey: "HomePlayWeatherLon")
        CLGeocoder().reverseGeocodeLocation(loc) { [weak self] marks, _ in
            guard let self, let city = marks?.first?.locality ?? marks?.first?.administrativeArea else { return }
            self.defaults.set(city, forKey: "HomePlayWeatherCity")
            // 2.0 depth：第一次抓的時候城市名還沒回來（反查比天氣慢）：回來了就補上，不用等下一次 30 分鐘的更新
            if var d = self.data, d.city != city { d.city = city; self.data = d; self.version += 1; self.onChange?() }
        }
        fetch(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { fetchWithCachedLocation() }

    private func fetchWithCachedLocation() {
        guard defaults.object(forKey: "HomePlayWeatherLat") != nil else {
            if status != .noLocation { status = .noLocation; version += 1; onChange?() }
            return
        }
        fetch(lat: defaults.double(forKey: "HomePlayWeatherLat"), lon: defaults.double(forKey: "HomePlayWeatherLon"))
    }

    // MARK: 網路

    private func fetch(lat: Double, lon: Double) {
        guard !fetching, Date().timeIntervalSince(lastFetch) > 60 else { return }
        fetching = true; lastFetch = Date()
        let city = defaults.string(forKey: "HomePlayWeatherCity")
        queue.async { [weak self] in
            let result = Self.download(lat: lat, lon: lon, city: city)
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetching = false
                guard let d = result else {
                    // 2.0 depth：抓不到（開機時 Wi‑Fi 還沒好、離線）：還沒有任何資料就 1 分鐘、再 5 分鐘後重試，不等 30 分鐘的計時器
                    if self.status != .offline { self.status = .offline; self.version += 1; self.onChange?() }
                    if self.data == nil, self.retries < 2 {
                        let wait: Double = self.retries == 0 ? 65 : 300
                        self.retries += 1
                        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.refresh() }
                    }
                    return
                }
                self.status = .ok; self.retries = 0
                let at = Date()
                self.updatedAt = at; self.defaults.set(at, forKey: "HomePlayWeatherLastAt")   // 2.0 P02：資料沒變也算剛更新過
                guard d != self.data else { self.version += 1; self.onChange?(); return }
                self.data = d; self.version += 1
                if let raw = try? JSONEncoder().encode(d) { self.defaults.set(raw, forKey: "HomePlayWeatherLast") }
                self.onChange?()
            }
        }
    }

    private static func getJSON(_ url: String) -> [String: Any]? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u); req.timeoutInterval = 15
        let sem = DispatchSemaphore(value: 0)
        var out: [String: Any]?
        URLSession.shared.dataTask(with: req) { d, _, _ in
            if let d, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { out = o }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 20)
        return out
    }

    private static func download(lat: Double, lon: Double, city: String?) -> WeatherData? {
        let ll = String(format: "latitude=%.3f&longitude=%.3f", lat, lon)
        guard let w = getJSON("https://api.open-meteo.com/v1/forecast?\(ll)&current=temperature_2m,weather_code,wind_speed_10m,relative_humidity_2m,is_day&hourly=temperature_2m,weather_code,is_day&daily=temperature_2m_max,temperature_2m_min,sunset,sunrise,weather_code&forecast_days=10&timezone=auto"),   // 2.0: 同一個請求多拿逐時、逐日（天氣 App：10 天、日出）
              let cur = w["current"] as? [String: Any], let t = (cur["temperature_2m"] as? NSNumber)?.doubleValue else { return nil }
        let daily = w["daily"] as? [String: Any]
        func first(_ k: String) -> Double? { ((daily?[k] as? [Any])?.first as? NSNumber)?.doubleValue }
        var sunset: String?
        if let s = (daily?["sunset"] as? [Any])?.first as? String, let i = s.firstIndex(of: "T") { sunset = String(s[s.index(after: i)...].prefix(5)) }
        var sunrise: String?   // 2.0 天氣 App：日出前後的天色
        if let s = (daily?["sunrise"] as? [Any])?.first as? String, let i = s.firstIndex(of: "T") { sunrise = String(s[s.index(after: i)...].prefix(5)) }
        var aqi: Double?
        if let a = getJSON("https://air-quality-api.open-meteo.com/v1/air-quality?\(ll)&current=us_aqi"),
           let c = a["current"] as? [String: Any] { aqi = (c["us_aqi"] as? NSNumber)?.doubleValue }
        let (hourly, dailyList) = forecast(w, now: cur["time"] as? String)
        return WeatherData(temp: t, hi: first("temperature_2m_max") ?? t, lo: first("temperature_2m_min") ?? t,
                           code: (cur["weather_code"] as? NSNumber)?.intValue ?? 0, wind: (cur["wind_speed_10m"] as? NSNumber)?.doubleValue ?? 0,
                           humidity: (cur["relative_humidity_2m"] as? NSNumber)?.doubleValue ?? 0, aqi: aqi, sunset: sunset, city: city,
                           night: (cur["is_day"] as? NSNumber).map { $0.intValue == 0 }, hourly: hourly, daily: dailyList, sunrise: sunrise)
    }

    /// 2.0：從同一份回應裡取接下來 12 小時（從目前這個整點起）與 5 天
    static func forecast(_ w: [String: Any], now: String?) -> ([WeatherHour]?, [WeatherDay]?) {
        var hours: [WeatherHour]?
        if let h = w["hourly"] as? [String: Any], let times = h["time"] as? [String], let temps = h["temperature_2m"] as? [Any],
           let codes = h["weather_code"] as? [Any] {
            let isDay = h["is_day"] as? [Any]
            let from = String((now ?? times.first ?? "").prefix(13))      // "2026-10-24T13"
            if let i0 = times.firstIndex(where: { String($0.prefix(13)) >= from }) {
                var out: [WeatherHour] = []
                for i in i0..<min(times.count, i0 + 12) where i < temps.count && i < codes.count {
                    guard let t = (temps[i] as? NSNumber)?.doubleValue else { continue }
                    out.append(WeatherHour(label: String(times[i].dropFirst(11).prefix(2)), temp: t, code: (codes[i] as? NSNumber)?.intValue ?? 0,
                                           night: ((isDay?[safe: i] as? NSNumber)?.intValue ?? 1) == 0))
                }
                hours = out.isEmpty ? nil : out
            }
        }
        var days: [WeatherDay]?
        if let d = w["daily"] as? [String: Any], let times = d["time"] as? [String], let hi = d["temperature_2m_max"] as? [Any],
           let lo = d["temperature_2m_min"] as? [Any], let codes = d["weather_code"] as? [Any] {
            var out: [WeatherDay] = []
            for i in 0..<min(times.count, 10) where i < hi.count && i < lo.count && i < codes.count {
                guard let h = (hi[i] as? NSNumber)?.doubleValue, let l = (lo[i] as? NSNumber)?.doubleValue else { continue }
                out.append(WeatherDay(date: times[i], hi: h, lo: l, code: (codes[i] as? NSNumber)?.intValue ?? 0))
            }
            days = out.isEmpty ? nil : out
        }
        return (hours, days)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
