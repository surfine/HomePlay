import AppKit
import Foundation
import QuartzCore
import Network
import CoreWLAN
import IOBluetooth
import IOKit
import IAP2
import Session
import H264
import Wire

enum Touch {
    /// {"type":"touch","contacts":[{"id":0,"x":..,"y":..,"down":..}]} → 第一个触点
    static func parse(_ text: String) -> (x: Double, y: Double, down: Bool)? {
        guard let d = text.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], o["type"] as? String == "touch",
              let c = (o["contacts"] as? [[String: Any]])?.first,
              let x = (c["x"] as? NSNumber)?.doubleValue, let y = (c["y"] as? NSNumber)?.doubleValue else { return nil }
        return (min(1, max(0, x)), min(1, max(0, y)), (c["down"] as? Bool) ?? false)
    }
}
