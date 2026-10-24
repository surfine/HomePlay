import AppKit
import CoreLocation

// 天氣錶面的真資料：Open-Meteo（免金鑰）＋ CoreLocation（降低精確度，只在天氣錶面第一次出現時才問「使用 App 期間」）。
// 定位拿不到／被拒絕：用 UserDefaults 裡上一次的位置；都沒有就讓錶面顯示「—」，不崩、不擋。
// 每 30 分鐘刷新；網路在背景佇列，結果回主執行緒發布並叫錶面重畫。
// 快照／測試：環境變數 HOMEPLAY_WEATHER_JSON='{"temp":22,"hi":25,"lo":19,"code":2,"wind":11,"humidity":76,"aqi":21,"sunset":"17:21","city":"臺北市"}'
// 直接當資料用（不連網、不問定位）；可再加 "night":true／false。

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
}

final class WeatherSource: NSObject, CLLocationManagerDelegate {
    static let shared = WeatherSource()
    static let usageKey = "NSLocationUsageDescription"
    static let envKey = "HOMEPLAY_WEATHER_JSON"

    private(set) var data: WeatherData?
    private(set) var version = 0
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
        if let json = ProcessInfo.processInfo.environment[Self.envKey], let d = Self.parse(json) {
            data = d; version += 1; return
        }
        if let raw = defaults.data(forKey: "HomePlayWeatherLast"), let d = try? JSONDecoder().decode(WeatherData.self, from: raw) {
            data = d; version += 1
        }
        DispatchQueue.main.async { [weak self] in self?.startOnMain() }
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
            if let city = marks?.first?.locality ?? marks?.first?.administrativeArea { self?.defaults.set(city, forKey: "HomePlayWeatherCity") }
        }
        fetch(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { fetchWithCachedLocation() }

    private func fetchWithCachedLocation() {
        guard defaults.object(forKey: "HomePlayWeatherLat") != nil else { return }
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
                guard let d = result, d != self.data else { return }
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
        guard let w = getJSON("https://api.open-meteo.com/v1/forecast?\(ll)&current=temperature_2m,weather_code,wind_speed_10m,relative_humidity_2m,is_day&daily=temperature_2m_max,temperature_2m_min,sunset&forecast_days=1&timezone=auto"),
              let cur = w["current"] as? [String: Any], let t = (cur["temperature_2m"] as? NSNumber)?.doubleValue else { return nil }
        let daily = w["daily"] as? [String: Any]
        func first(_ k: String) -> Double? { ((daily?[k] as? [Any])?.first as? NSNumber)?.doubleValue }
        var sunset: String?
        if let s = (daily?["sunset"] as? [Any])?.first as? String, let i = s.firstIndex(of: "T") { sunset = String(s[s.index(after: i)...].prefix(5)) }
        var aqi: Double?
        if let a = getJSON("https://air-quality-api.open-meteo.com/v1/air-quality?\(ll)&current=us_aqi"),
           let c = a["current"] as? [String: Any] { aqi = (c["us_aqi"] as? NSNumber)?.doubleValue }
        return WeatherData(temp: t, hi: first("temperature_2m_max") ?? t, lo: first("temperature_2m_min") ?? t,
                           code: (cur["weather_code"] as? NSNumber)?.intValue ?? 0, wind: (cur["wind_speed_10m"] as? NSNumber)?.doubleValue ?? 0,
                           humidity: (cur["relative_humidity_2m"] as? NSNumber)?.doubleValue ?? 0, aqi: aqi, sunset: sunset, city: city,
                           night: (cur["is_day"] as? NSNumber).map { $0.intValue == 0 })
    }
}
