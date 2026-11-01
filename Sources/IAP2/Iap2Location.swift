import Foundation

// iAP2 車機定位（LocationInformation）：配件在識別資訊宣告定位元件（參數 22），
// iPhone 送 0xFFFA StartLocationInformation 指名要哪幾種 NMEA（1 GGA、2 RMC、3 GSV、4 車速 PASCD），
// 配件之後每句 NMEA 各包一則 0xFFFB（參數 0＝句子，NUL 結尾），0xFFFC 停。
// 欄位編號照 LIVI iap2-csm messages/location.rs、identification.rs（只取協定事實，程式自寫）。
// 探針（D4 遠期構想 P0）：HOMEPLAY_FAKE_GPS=緯度,經度[,航向°,車速 km/h] 才宣告；平常不宣告，行為不變。

package enum Iap2Location {
    package static let start: UInt16 = 0xfffa
    package static let information: UInt16 = 0xfffb
    package static let stop: UInt16 = 0xfffc
    package static let componentParameter: UInt16 = 22

    /// 識別資訊的定位元件：0 id、1 名稱、17 GGA、18 RMC（旗標＝空載荷）
    package static func component(name: String) -> Iap2Csm.Parameter {
        Iap2Csm.Parameter(id: componentParameter, payload: Iap2Csm.encodeParameters([
            Iap2Csm.Parameter(id: 0, payload: [0, 0]),
            Iap2Csm.Parameter(id: 1, payload: Array(name.utf8) + [0]),
            Iap2Csm.Parameter(id: 17, payload: []),
            Iap2Csm.Parameter(id: 18, payload: []),
        ]))
    }

    /// 0xFFFA 要的句型（三字母）
    package static func requested(_ f: Iap2Csm.Frame) -> [String] {
        let names: [UInt16: String] = [1: "GGA", 2: "RMC", 3: "GSV", 4: "SCD"]
        return f.parameters.compactMap { names[$0.id] }
    }

    package static func frame(_ sentence: String) -> Iap2Csm.Frame {
        Iap2Csm.Frame(messageId: information, parameters: [Iap2Csm.Parameter(id: 0, payload: Array(sentence.utf8) + [0])])
    }
}

/// 假 GPS：從起點沿固定航向等速前進，每次 sentences(at:) 交出那一刻的 GGA／RMC
package struct FakeGPS: Sendable {
    package var lat: Double
    package var lon: Double
    package var heading: Double      // 度，0＝北、90＝東
    package var speedKmh: Double
    private var last: Date?

    package init(lat: Double, lon: Double, heading: Double = 0, speedKmh: Double = 0) {
        self.lat = lat; self.lon = lon; self.heading = heading; self.speedKmh = speedKmh
    }

    /// HOMEPLAY_FAKE_GPS="25.0339,121.5645,90,30"
    package static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> FakeGPS? {
        guard let s = env["HOMEPLAY_FAKE_GPS"] else { return nil }
        let v = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard v.count >= 2, (-90...90).contains(v[0]), (-180...180).contains(v[1]) else { return nil }
        return FakeGPS(lat: v[0], lon: v[1], heading: v.count > 2 ? v[2] : 0, speedKmh: v.count > 3 ? v[3] : 0)
    }

    /// 前進到 now，交出要的句型（不含 $ 前的換行，不含 \r\n）
    package mutating func sentences(at now: Date, wanted: [String]) -> [String] {
        if let last {
            let meters = speedKmh / 3.6 * now.timeIntervalSince(last)
            let r = heading * .pi / 180
            lat += meters * cos(r) / 111_320
            lon += meters * sin(r) / (111_320 * max(0.01, cos(lat * .pi / 180)))
        }
        last = now
        var out: [String] = []
        if wanted.contains("GGA") { out.append(Self.gga(lat: lat, lon: lon, at: now)) }
        if wanted.contains("RMC") { out.append(Self.rmc(lat: lat, lon: lon, knots: speedKmh / 1.852, course: heading, at: now)) }
        return out
    }

    package static func checksum(_ body: String) -> String {
        String(format: "%02X", body.utf8.reduce(UInt8(0)) { $0 ^ $1 })
    }

    /// 度 → NMEA 的 (d)ddmm.mmmm 與半球
    package static func coord(_ deg: Double, isLat: Bool) -> (String, String) {
        let a = abs(deg), d = Int(a), m = (a - Double(d)) * 60
        let s = String(format: isLat ? "%02d%07.4f" : "%03d%07.4f", d, m)
        return (s, isLat ? (deg >= 0 ? "N" : "S") : (deg >= 0 ? "E" : "W"))
    }

    private static func utc(_ now: Date, _ fmt: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = fmt
        return f.string(from: now)
    }

    package static func gga(lat: Double, lon: Double, at now: Date) -> String {
        let (la, ns) = coord(lat, isLat: true), (lo, ew) = coord(lon, isLat: false)
        let body = "GPGGA,\(utc(now, "HHmmss.SS")),\(la),\(ns),\(lo),\(ew),1,10,0.8,10.0,M,0.0,M,,"
        return "$\(body)*\(checksum(body))"
    }

    package static func rmc(lat: Double, lon: Double, knots: Double, course: Double, at now: Date) -> String {
        let (la, ns) = coord(lat, isLat: true), (lo, ew) = coord(lon, isLat: false)
        let body = "GPRMC,\(utc(now, "HHmmss.SS")),A,\(la),\(ns),\(lo),\(ew),\(String(format: "%.2f", knots)),\(String(format: "%.1f", course)),\(utc(now, "ddMMyy")),,,A"
        return "$\(body)*\(checksum(body))"
    }
}
